import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// The Tall island (Planning.md, Accepted 2026-10-31 "Tall island:
/// switching pages"; the design's px halved): a 27 pt capsule of 21 pt
/// items, 8 pt from the work area's side edge and 8 pt from the panel, which
/// docks that much further in; lined up with the panel's top in the top
/// corners and its bottom in the bottom corners. Pointing shows a name
/// label on the panel's side and never switches; a click switches.
@MainActor
final class PanelIslandTests: XCTestCase {
    private typealias L = PanelIslandLayout
    private let size = CGSize(width: 340, height: 560)
    /// These tests were written for the standing island; the default is
    /// now the screen's bottom edge (`PanelIslandPositionTests`).
    private let standing: PanelIslandSpot = .screenSideCornerEnd

    // MARK: Frame math

    private func placed(in visible: CGRect, corner: ScreenCorner) -> (panel: CGRect, island: CGRect) {
        let area = L.panelArea(in: visible, corner: corner, spot: standing)
        let panel = PanelGeometry.panelFrame(in: area, size: size, corner: corner)
        return (panel, L.islandFrame(panelFrame: panel, corner: corner, spot: standing))
    }

    private func assertPlacement(in visible: CGRect, corner: ScreenCorner, _ note: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let (panel, island) = placed(in: visible, corner: corner)
        let what = "\(corner) \(note)"
        XCTAssertEqual(island.width, 27, accuracy: 0.01, "\(what): 27 pt wide", file: file, line: line)
        XCTAssertEqual(island.height, CGFloat(99), accuracy: 0.01, "\(what): four 21 pt items", file: file, line: line)
        switch corner {
        case .topRight, .bottomRight:
            XCTAssertEqual(visible.maxX - island.maxX, 10, accuracy: 0.01, "\(what): 10 pt from the edge (L2)", file: file, line: line)
            XCTAssertEqual(island.minX - panel.maxX, 6, accuracy: 0.01, "\(what): 6 pt from the panel (L2)", file: file, line: line)
            XCTAssertEqual(visible.maxX - panel.maxX, 43, accuracy: 0.01, "\(what): the panel docks 43 pt in", file: file, line: line)
        case .topLeft, .bottomLeft:
            XCTAssertEqual(island.minX - visible.minX, 10, accuracy: 0.01, "\(what): 10 pt from the edge (L2)", file: file, line: line)
            XCTAssertEqual(panel.minX - island.maxX, 6, accuracy: 0.01, "\(what): 6 pt from the panel (L2)", file: file, line: line)
            XCTAssertEqual(panel.minX - visible.minX, 43, accuracy: 0.01, "\(what): the panel docks 43 pt in", file: file, line: line)
        }
        switch corner {
        case .topRight, .topLeft:
            XCTAssertEqual(panel.maxY - island.maxY, L.endInset, accuracy: 0.5, "\(what): level with the top row (L3)", file: file, line: line)
            XCTAssertEqual(visible.maxY - panel.maxY, PanelGeometry.screenInset, accuracy: 0.01, file: file, line: line)
        case .bottomRight, .bottomLeft:
            XCTAssertEqual(island.minY - panel.minY, L.endInset, accuracy: 0.5, "\(what): level with the bottom bar (L3)", file: file, line: line)
            XCTAssertEqual(panel.minY - visible.minY, PanelGeometry.screenInset, accuracy: 0.01, file: file, line: line)
        }
        XCTAssertTrue(visible.contains(island), "\(what): on screen", file: file, line: line)
        XCTAssertFalse(island.intersects(panel), "\(what): beside the panel, never on it", file: file, line: line)
    }

    func testTheIslandSitsBetweenThePanelAndTheSideEdgeInEveryCorner() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        for corner in ScreenCorner.allCases {
            assertPlacement(in: visible, corner: corner, "plain screen")
        }
    }

    func testWithTheDockOnTheIslandsSideTheIslandSits8FromTheDock() {
        // The work area stops at the Dock: a 64 pt Dock on the right, on the
        // left, and at the bottom (a second display at a negative origin).
        let dockRight = CGRect(x: 0, y: 0, width: 1440 - 64, height: 875)
        let dockLeft = CGRect(x: 64, y: 0, width: 1440 - 64, height: 875)
        let dockBottom = CGRect(x: -1920, y: 64, width: 1920, height: 1080 - 64 - 25)
        for corner in [ScreenCorner.topRight, .bottomRight] { assertPlacement(in: dockRight, corner: corner, "Dock on the right") }
        for corner in [ScreenCorner.topLeft, .bottomLeft] { assertPlacement(in: dockLeft, corner: corner, "Dock on the left") }
        for corner in ScreenCorner.allCases { assertPlacement(in: dockBottom, corner: corner, "Dock at the bottom") }
        XCTAssertEqual(placed(in: dockRight, corner: .topRight).island.maxX, 1440 - 64 - 10, accuracy: 0.01,
                       "10 pt from the Dock, not from the screen's edge")
    }

    func testThePanelsAreaKeepsTheIslandsStripAndItsResizeLimitToo() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        XCTAssertEqual(L.panelArea(in: visible, corner: .topRight, spot: standing), CGRect(x: 0, y: 0, width: 1440 - 31, height: 875))
        XCTAssertEqual(L.panelArea(in: visible, corner: .bottomLeft, spot: standing), CGRect(x: 31, y: 0, width: 1440 - 31, height: 875))
        let maximum = PanelGeometry.resizeMaximumSize(in: L.panelArea(in: visible, corner: .topRight, spot: standing))
        XCTAssertEqual(maximum.width, 1440 - 12 - 43, "the widest panel still leaves the island its room")
        // A panel pushed against the island's side stays clear of it.
        let pushed = PanelGeometry.constrainedFrame(CGRect(x: 1300, y: 300, width: 340, height: 560),
                                                    to: L.panelArea(in: visible, corner: .topRight, spot: standing))
        XCTAssertEqual(visible.maxX - pushed.maxX, 43, accuracy: 0.01)
    }

    func testTheItemsRunTopToBottomInThePagesOrderAndTheLabelSitsOnThePanelsSide() {
        let island = CGRect(x: 1405, y: 676, width: 27, height: L.height())
        XCTAssertEqual(L.pages, [.tasks, .notes, .calendar, .canvas], "the old switch's pages, in its order")
        for index in L.pages.indices {
            let item = L.itemFrame(index, in: island)
            XCTAssertEqual(item.size, CGSize(width: 21, height: 21))
            XCTAssertEqual(item.minX - island.minX, 3, accuracy: 0.01)
            XCTAssertEqual(island.maxY - item.maxY, 3 + CGFloat(index) * 24, accuracy: 0.01)
        }
        XCTAssertEqual(L.itemFrame(3, in: island).minY - island.minY, 3, accuracy: 0.01)
        let rightLabel = L.labelWindowFrame(island: island, corner: .topRight, spot: standing)
        XCTAssertEqual(island.minX - rightLabel.maxX, 6, accuracy: 0.01, "right corners: the label sits left of the island")
        let leftLabel = L.labelWindowFrame(island: island, corner: .bottomLeft, spot: standing)
        XCTAssertEqual(leftLabel.minX - island.maxX, 6, accuracy: 0.01, "left corners: right of it")
        XCTAssertEqual(L.labelHeight, 20)
        XCTAssertEqual(L.labelFontSize, 11)
    }

    // MARK: Pointing and clicking

    func testPointingShowsTheLabelOnlyAndNeverSwitches() throws {
        let state = PanelUIState()
        state.loadPageContent()
        var requests: [PanelPage] = []
        var approaches = 0
        let a = state.island.requests.sink { requests.append($0) }
        let b = state.island.approaches.sink { approaches += 1 }
        defer { a.cancel(); b.cancel() }
        state.island.point(at: .calendar)
        state.island.point(at: .notes)
        XCTAssertEqual(state.selectedSection, .tasks, "pointing never changes the page")
        XCTAssertEqual(requests, [])
        XCTAssertEqual(state.island.pointed, .notes)
        XCTAssertEqual(approaches, 1, "arriving on the island builds the other pages once")
        state.island.leave(.calendar)
        XCTAssertEqual(state.island.pointed, .notes, "leaving an item the pointer already left changes nothing")
        state.island.leave(.notes)
        XCTAssertNil(state.island.pointed)

        // The label: only the pointed item's row draws (hosted in a window
        // and drawn from its own view tree; the flat look, as glass draws
        // artefacts off screen). Awake, the first name waits 400 ms (L8).
        state.island.wake()
        state.island.point(at: .calendar)
        spin(L.labelDelay + 0.1)
        let host = NSHostingView(rootView: PanelIslandLabels(model: state.island)
            .atticDesign(AtticDesignContext(mode: .light, reduceMotion: true, controls: .craft)))
        let labelSize = CGSize(width: L.labelRoom, height: L.height())
        host.frame = CGRect(origin: .zero, size: labelSize)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: labelSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        spin(0.3)
        func rowInk(_ row: Int) throws -> CGFloat {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsHigh) / host.bounds.height
            let top = Int((L.inset + CGFloat(row) * (L.item + L.gap)) * scale)
            var ink: CGFloat = 0
            for y in stride(from: top, to: top + Int(L.item * scale), by: 2) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                    ink = max(ink, bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0)
                }
            }
            return ink
        }
        XCTAssertGreaterThan(try rowInk(2), 0.5, "Calendar's label shows")
        XCTAssertLessThan(try rowInk(0), 0.01, "no other label")
        XCTAssertLessThan(try rowInk(1), 0.01)
    }

    func testIslandOffersPullOutAndPutBackAsVoiceOverActions() throws {
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = true
        defer {
            AtticMotionPreference.systemReduceMotionOverride = nil
            AtticTransparencySeam.systemOverride = nil
        }
        try withController(configure: { _ in
            AtticMotionPreference.systemReduceMotionOverride = true
            AtticTransparencySeam.systemOverride = true
        }) { controller, state, _ in
            let host = try XCTUnwrap(controller.islandWindowsForTesting.island.contentView)
            @MainActor func actions() throws -> [NSAccessibilityCustomAction] {
                let item = try XCTUnwrap(elements(host).first { $0.accessibilityIdentifier?() == PanelPage.notes.accessibilityIdentifier })
                return (item as? NSObject)?.value(forKey: "accessibilityCustomActions") as? [NSAccessibilityCustomAction] ?? []
            }
            @MainActor func run(_ action: NSAccessibilityCustomAction) {
                if let handler = action.handler { _ = handler() }
                else if let target = action.target as? NSObject { _ = target.perform(action.selector, with: action) }
                spin(0.4)
            }
            @MainActor func menu() throws -> [AtticMenuCommand] {
                let item = try XCTUnwrap(elements(host).first { $0.accessibilityIdentifier?() == PanelPage.notes.accessibilityIdentifier })
                let frame = try XCTUnwrap((item as? NSAccessibilityElementProtocol)?.accessibilityFrame())
                let window = controller.islandWindowsForTesting.island
                let point = window.convertPoint(fromScreen: CGPoint(x: frame.midX, y: frame.midY))
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                    timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                return try XCTUnwrap(AtticContextMenus.commands(for: event))
            }
            XCTAssertEqual(try menu().map(\.title), ["Open in Own Panel"])
            XCTAssertEqual(try actions().map(\.name), ["Open in Own Panel"])
            run(try XCTUnwrap(actions().first))
            XCTAssertTrue(state.island.outPages.contains(.notes))
            XCTAssertEqual(try menu().map(\.title), ["Open in Own Panel", "Put Back"])
            XCTAssertEqual(try actions().map(\.name), ["Open in Own Panel", "Put Back"])
            try XCTUnwrap(menu().last).action()
            spin(0.4)
            XCTAssertFalse(state.island.outPages.contains(.notes))
        }
    }

    func testAClickOnAnItemSwitchesThroughThePanelsPathAndVoiceOverCanPressIt() throws {
        try withController { controller, state, _ in
            let windows = controller.islandWindowsForTesting
            let island = try XCTUnwrap(windows.island.contentView)
            @MainActor func item(_ page: PanelPage) throws -> AnyObject {
                let found = elements(island).first { ($0.accessibilityIdentifier?() ?? "") == page.accessibilityIdentifier }
                return try XCTUnwrap(found, "\(page) is a button on the island")
            }
            let group = try XCTUnwrap(elements(island).first { ($0.accessibilityIdentifier?() ?? "") == "panel-section-picker" })
            XCTAssertEqual(group.accessibilityLabel?(), "Pages")
            for page in PanelIslandLayout.pages {
                let element = try item(page)
                XCTAssertEqual(element.accessibilityLabel?(), page.title, "named after its page")
                XCTAssertEqual(element.accessibilityRole?(), .button)
            }
            XCTAssertEqual(try item(.tasks).isAccessibilitySelected?(), true, "the current page is selected")

            state.island.point(at: .notes)
            spin(0.2)
            XCTAssertEqual(state.selectedSection, .tasks, "pointing doesn't switch")

            XCTAssertTrue(try item(.notes).accessibilityPerformPress?() ?? false, "VoiceOver presses it")
            spin(0.6)
            XCTAssertEqual(state.selectedSection, .notes, "a click switches")
            XCTAssertEqual(state.island.page, .notes)
            XCTAssertEqual(try item(.notes).isAccessibilitySelected?(), true)
            XCTAssertEqual(try item(.tasks).isAccessibilitySelected?(), false)

            state.island.click(.calendar)
            spin(0.6)
            XCTAssertEqual(state.selectedSection, .calendar)
        }
    }

    // MARK: Belongs to the panel

    func testTheIslandShowsHidesAndMovesWithThePanel() throws {
        try withController { controller, state, panel in
            let windows = controller.islandWindowsForTesting
            XCTAssertTrue(windows.island.isVisible, "on screen with the panel")
            XCTAssertTrue(windows.label.isVisible)
            XCTAssertTrue(windows.island.parent === panel, "a child window of the panel")
            XCTAssertTrue(windows.label.ignoresMouseEvents, "the label never takes the pointer")
            XCTAssertEqual(windows.presentedOpacity, 1, accuracy: 0.01)
            @MainActor func assertBeside(_ corner: ScreenCorner, _ note: String) {
                let surface = controller.panelVisibleFrameForTesting
                let capsule = windows.islandFrame
                let window = windows.island.frame
                let expected = PanelIslandLayout.islandFrame(panelFrame: surface, corner: corner, spot: standing)
                let margin = PanelIslandLayout.windowMargin
                XCTAssertEqual(capsule, expected, note)
                XCTAssertEqual(window, capsule.insetBy(dx: -margin, dy: -margin), note)
            }
            assertBeside(.topRight, "docked top right")

            // Moved and resized (a screen change, live resize): it follows.
            let moved = panel.visibleContentFrame.offsetBy(dx: -120, dy: -80).insetBy(dx: 0, dy: 20)
            panel.setVisibleContentFrame(moved, display: false)
            spin(0.05)
            assertBeside(.topRight, "after a move and resize")

            // A drag's docking preview: it goes to that corner's side.
            state.dockingPreviewCorner = .bottomLeft
            spin(0.05)
            assertBeside(.bottomLeft, "previewing the bottom-left corner")
            state.dockingPreviewCorner = nil
            spin(0.05)
            assertBeside(.topRight, "back on the docked corner's side")

            // The swipe that dismisses: it goes with the panel under the
            // fingers, drawn by its stand-in in the panel's motion layer
            // (Accepted "Tall island", "Hiding and showing as one shape").
            panel.onTrackpadDismissProgress?(120)
            spin(0.05)
            XCTAssertTrue(try content(panel).isIslandStandInShown, "with the panel's collapse")
            XCTAssertLessThan(windows.presentedOpacity, 0.01, "its windows step aside")
            panel.onTrackpadDismissCancelled?()
            spin(0.8)
            XCTAssertEqual(windows.presentedOpacity, 1, accuracy: 0.01, "back with the panel")

            // Hidden with the panel, shown with it again.
            var hidden = false
            _ = controller.requestHide { hidden = $0 == .hidden }
            spin(until: { hidden })
            XCTAssertFalse(windows.island.isVisible, "hidden with the panel")
            XCTAssertFalse(windows.label.isVisible)
            let screen = try XCTUnwrap(controller.currentScreen)
            XCTAssertTrue(controller.show(on: screen, corner: .bottomLeft))
            spin(0.8)
            XCTAssertTrue(windows.island.isVisible, "and shown with it")
            XCTAssertEqual(windows.presentedOpacity, 1, accuracy: 0.01)
            assertBeside(.bottomLeft, "docked bottom left")
        }
    }

    func testPassthroughCountsTheIsland() throws {
        try withController { controller, state, panel in
            let windows = controller.islandWindowsForTesting
            // At rest (D4): its dots' capsule and the zone that wakes it.
            XCTAssertFalse(state.island.isAwake)
            let rest = windows.restFrame
            XCTAssertTrue(controller.containsScreenPoint(CGPoint(x: rest.midX, y: rest.midY)), "the resting island is the panel")
            state.island.wake()
            let centre = CGPoint(x: windows.islandFrame.midX, y: windows.islandFrame.midY)
            XCTAssertTrue(controller.containsScreenPoint(centre), "pointing at the island is pointing at the panel")
            let item = PanelIslandLayout.itemFrame(3, in: windows.islandFrame)
            XCTAssertTrue(controller.containsScreenPoint(CGPoint(x: item.midX, y: item.midY)))
            controller.updateMousePassthrough(at: centre)
            XCTAssertFalse(panel.ignoresMouseEvents, "the island is never click-through")
            let beyond = CGPoint(x: windows.islandFrame.maxX + 4, y: windows.islandFrame.midY)
            XCTAssertFalse(controller.containsScreenPoint(beyond), "past the island is outside the panel")
        }
    }

    /// The island window's clear margin (room for its focus ring) never
    /// takes a click meant for the window under it; only the capsule does.
    /// The label window never takes the pointer at all.
    func testTheIslandsClearMarginPassesThePointerThrough() throws {
        try withController { controller, _, _ in
            let windows = controller.islandWindowsForTesting
            let capsule = windows.islandFrame
            let margin = PanelIslandLayout.windowMargin
            XCTAssertTrue(windows.island.frame.contains(CGPoint(x: capsule.maxX + margin / 2, y: capsule.midY)))
            let inMargin = [CGPoint(x: capsule.maxX + margin / 2, y: capsule.midY),
                            CGPoint(x: capsule.minX - margin / 2, y: capsule.midY),
                            CGPoint(x: capsule.midX, y: capsule.maxY + margin / 2),
                            CGPoint(x: capsule.midX, y: capsule.minY - margin / 2)]
            for point in inMargin {
                controller.updateMousePassthrough(at: point)
                XCTAssertTrue(windows.island.ignoresMouseEvents, "the clear margin at \(point) passes clicks through")
                XCTAssertTrue(windows.label.ignoresMouseEvents)
            }
            controller.updateMousePassthrough(at: CGPoint(x: capsule.midX, y: capsule.midY))
            XCTAssertFalse(windows.island.ignoresMouseEvents, "the capsule takes the pointer")
            XCTAssertTrue(windows.label.ignoresMouseEvents, "the label never takes the pointer")
            let item = PanelIslandLayout.itemFrame(0, in: capsule)
            controller.updateMousePassthrough(at: CGPoint(x: item.midX, y: item.midY))
            XCTAssertFalse(windows.island.ignoresMouseEvents, "an item takes the pointer")
            // Pointing elsewhere (here, the panel) leaves the capsule
            // hittable, for a click or an accessibility hit test there.
            controller.updateMousePassthrough(at: CGPoint(x: windows.island.frame.maxX + 40, y: capsule.midY))
            controller.updateMousePassthrough(at: CGPoint(x: capsule.maxX + margin / 2, y: capsule.midY))
            controller.updateMousePassthrough(at: CGPoint(x: windows.island.frame.minX - 40, y: capsule.midY))
            XCTAssertFalse(windows.island.ignoresMouseEvents, "off the island window, it still takes the pointer")
        }
    }

    // MARK: The owner's recording of build 1 (31 Oct)

    /// Every item's icon has the same ink and weight, as the design draws
    /// them (`isl.ink`); only the current page sits on the chip.
    func testEveryItemsIconHasTheSameInk() {
        for solid in [true, false] {
            let selected = L.face(isSelected: true, solid: solid)
            let other = L.face(isSelected: false, solid: solid)
            XCTAssertEqual(selected.ink, other.ink, "one ink (solid \(solid))")
            XCTAssertEqual(selected.weight, other.weight, "one weight (solid \(solid))")
            XCTAssertEqual(other.ink, .glyph, "full ink")
        }
    }

    /// One name label on screen: pointing at the next item takes the last
    /// one away at once; leaving the island lets it fade.
    func testOnlyOneLabelShowsAtATime() {
        XCTAssertFalse(L.labelFadesOut(pointed: .notes), "another item pointed: the old label goes at once")
        XCTAssertTrue(L.labelFadesOut(pointed: nil), "off the island: it fades")
    }

    // MARK: Hide timing (the owner's recording of build 1, 31 Oct)

    /// A Swoop hide takes Swoop's own 0.22 s, and the island goes with the
    /// panel instead of staying until the panel vanishes. Since Accepted
    /// "Tall island", "Hiding and showing as one shape" ("the panel and the
    /// island shrink together, on the same curve and time"), the island no
    /// longer fades on its own: its stand-in is in the panel's motion layer,
    /// and fades only at the very end, as the panel does.
    func testASwoopHideTakesSwoopsTimeAndTheIslandFadesAlongside() throws {
        try withController(configure: { $0.hideAnimation = .swoop }) { controller, _, panel in
            let windows = controller.islandWindowsForTesting
            let container = try content(panel)
            var standInShown = false, motionAlpha: Float = 0
            let duration = PanelHideAnimation.swoop.defaultHideDuration
            let start = CACurrentMediaTime()
            var hiddenAt: CFTimeInterval?
            _ = controller.requestHide { if $0 == .hidden { hiddenAt = CACurrentMediaTime() } }
            // The pointer keeps moving away as the hide runs (the global
            // pointer monitor sees every move).
            let from = CGPoint(x: panel.visibleContentFrame.minX - 20, y: panel.visibleContentFrame.midY)
            var trace = ""
            var progress = 0.0, alpha: CGFloat = 1
            var step = 0
            while hiddenAt == nil, CACurrentMediaTime() - start < 3 {
                step += 1
                controller.updateMousePassthrough(at: CGPoint(x: from.x - CGFloat(step) * 6, y: from.y - CGFloat(step) * 2))
                RunLoop.current.run(until: Date().addingTimeInterval(0.016))
                let now = CACurrentMediaTime() - start
                if progress == 0, now >= duration * 0.6 {
                    progress = controller.displayedProgressForProbe
                    alpha = windows.presentedOpacity
                    standInShown = container.isIslandStandInShown
                    motionAlpha = container.motionOpacity()
                }
                trace += String(format: " %.0f:%.2f/%.2f", now * 1000, controller.displayedProgressForProbe, windows.presentedOpacity)
            }
            let took = try XCTUnwrap(hiddenAt) - start
            XCTAssertLessThan(took, duration + 0.12, "hidden in Swoop's own time (took \(took) s;\(trace))")
            XCTAssertGreaterThan(progress, 0.3, "well on its way at 60 % of the time (\(trace))")
            XCTAssertTrue(standInShown, "the island is drawn in the panel's motion layer (\(trace))")
            XCTAssertLessThan(alpha, 0.01, "its windows are empty while the panel moves (\(alpha) at 60 %)")
            XCTAssertGreaterThan(motionAlpha, 0.85, "not fading on its own: one shape with the panel (\(motionAlpha) at 60 %)")
            XCTAssertFalse(windows.island.isVisible)
            XCTAssertFalse(panel.isVisible)
        }
    }

    // MARK: Hiding and showing as one shape

    // Planning.md, Accepted "Tall island", "Hiding and showing as one
    // shape": the panel and the island shrink together, on the same curve
    // and time, toward the island's outer corner, and grow back out of it,
    // for every hide animation and the dismissing swipe; under Reduce
    // Motion both fade together.

    /// The docked panel's window holds the island's region (its margin is
    /// 40 pt, a floating panel's 28), and the extra margin is click-through
    /// like the rest of it.
    func testTheDockedPanelsMarginHoldsTheIslandAndLetsClicksThrough() throws {
        try withController { controller, _, panel in
            let container = try content(panel)
            XCTAssertEqual(AtticStyle.dockedPanelMargin, 40)
            XCTAssertEqual(AtticStyle.panelElevationMargin, 28, "floating panels keep 28")
            XCTAssertEqual(panel.nativeMargin, AtticStyle.dockedPanelMargin)
            let surface = panel.visibleContentFrame
            let island = controller.islandWindowsForTesting.islandFrame
            XCTAssertTrue(panel.frame.contains(island), "the island's region is inside the panel's window")
            // Between 28 and 40 pt out, off the island and its gap.
            let outside = [CGPoint(x: surface.midX, y: surface.maxY + 34), CGPoint(x: surface.midX, y: surface.minY - 34),
                           CGPoint(x: surface.minX - 34, y: surface.midY), CGPoint(x: surface.maxX + 20, y: surface.minY + 40),
                           CGPoint(x: island.maxX + 3, y: island.midY), CGPoint(x: surface.minX - 30, y: surface.maxY + 30)]
            for point in outside {
                XCTAssertTrue(panel.frame.contains(point), "\(point) is in the window's margin")
                controller.updateMousePassthrough(at: point)
                XCTAssertTrue(panel.ignoresMouseEvents, "the margin at \(point) lets clicks through")
                XCTAssertFalse(controller.containsScreenPoint(point))
                let local = CGPoint(x: point.x - panel.frame.minX, y: point.y - panel.frame.minY)
                XCTAssertNil(container.hitTest(local), "nothing in the window takes \(point)")
            }
            controller.updateMousePassthrough(at: CGPoint(x: surface.midX, y: surface.midY))
            XCTAssertFalse(panel.ignoresMouseEvents, "the surface takes the pointer")
        }
    }

    /// At rest the stand-in draws nothing, takes no hit and is no
    /// accessibility element: the island's windows are the live island.
    func testAtRestTheStandInTakesNoHitsAndIsNoAccessibilityElement() throws {
        try withController { controller, _, panel in
            let container = try content(panel)
            let windows = controller.islandWindowsForTesting
            let standIn = windows.standIn
            XCTAssertTrue(standIn.isDescendant(of: container), "in the panel's motion layer")
            XCTAssertFalse(container.isIslandStandInShown)
            XCTAssertEqual(standIn.layer?.opacity, 0)
            XCTAssertEqual(windows.presentedOpacity, 1, accuracy: 0.01, "the windows are the island")
            XCTAssertEqual(local(standIn.frame, in: panel, toScreen: true), windows.island.frame, "over the island window")
            let item = PanelIslandLayout.itemFrame(0, in: windows.islandFrame)
            let point = CGPoint(x: item.midX - panel.frame.minX, y: item.midY - panel.frame.minY)
            XCTAssertNil(container.hitTest(point), "the stand-in takes no hit")
            XCTAssertFalse(standIn.isAccessibilityElement())
            XCTAssertTrue((standIn.accessibilityChildren() ?? []).isEmpty)
            XCTAssertNil(standIn.accessibilityHitTest(CGPoint(x: item.midX, y: item.midY)))
            let ids = elements(panel).compactMap { $0.accessibilityIdentifier?() }
            for page in PanelPage.allCases {
                XCTAssertFalse(ids.contains(page.accessibilityIdentifier), "the panel window has no \(page) item")
            }
        }
    }

    /// "Motion: page switch and hide" (Accepted 2026-11-02): Slide hides on
    /// an accelerating curve (`hideTiming`'s start, ending fast) and its
    /// last part fades out, so nothing sits in the corner. The reveal
    /// keeps its curve and comes back fully opaque. Reduce Motion is off
    /// here (`withController` states it).
    func testSlideHidesOnAnAcceleratingCurveAndItsLastPartFades() throws {
        try withController(configure: { $0.hideAnimation = .slide }) { controller, _, panel in
            let container = try content(panel)
            var hidden = false
            _ = controller.requestHide { hidden = $0 == .hidden }
            let key = "attic.panel.collapse"
            var running: (CALayer, CAAnimation)?
            let deadline = Date().addingTimeInterval(1)
            while running == nil, Date() < deadline {
                running = container.subviews.compactMap(\.layer).compactMap { layer in
                    layer.animation(forKey: key).map { (layer, $0) }
                }.first
                if running == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.003)) }
            }
            let (layer, animation) = try XCTUnwrap(running, "a timed Slide hide")
            var samples: [(fraction: Double, progress: Double, opacity: Float)] = []
            layer.speed = 0
            layer.timeOffset = animation.beginTime
            CATransaction.flush()
            for fraction in [0.25, 0.5, 0.6, 0.8, 0.95] {
                layer.timeOffset = animation.beginTime + animation.duration * fraction
                CATransaction.flush()
                samples.append((fraction, controller.displayedProgressForProbe, container.motionOpacity(presented: true)))
            }
            layer.speed = 1
            layer.timeOffset = 0
            let note = samples.map { String(format: "%.2f: %.2f/%.2f", $0.fraction, $0.progress, $0.opacity) }.joined(separator: ", ")
            // Accelerating: behind the clock all the way (the reveal's
            // ease-out was 70 % there by a quarter).
            for sample in samples.prefix(4) {
                XCTAssertLessThan(sample.progress, sample.fraction, "accelerating (\(note))")
            }
            XCTAssertLessThan(samples[0].progress, 0.12, "slow to start (\(note))")
            XCTAssertEqual(samples[0].opacity, 1, accuracy: 0.01, "opaque early (\(note))")
            XCTAssertEqual(samples[1].opacity, 1, accuracy: 0.01, "opaque half way (\(note))")
            XCTAssertLessThan(samples[3].opacity, 0.9, "fading at the end (\(note))")
            XCTAssertLessThan(samples[4].opacity, 0.25, "nearly gone (\(note))")
            spin(until: { hidden })
            XCTAssertTrue(hidden)
            let screen = try XCTUnwrap(controller.currentScreen)
            XCTAssertTrue(controller.show(on: screen, corner: .topRight))
            spin(0.6)
            XCTAssertEqual(container.motionOpacity(presented: true), 1, accuracy: 0.01, "the reveal is opaque")
            XCTAssertEqual(container.motionOpacity(presented: false), 1, accuracy: 0.01)
            XCTAssertTrue(container.motionIsAtRest)
        }
    }

    /// Slide and Swoop, from every corner: at 30 % and 70 % of a hide and
    /// back on the reveal, the island's stand-in shows (the windows are
    /// empty) and is drawn by the panel's own transform about the island's
    /// outer corner, in screen points.
    func testSlideAndSwoopHideTheIslandWithThePanelIntoItsOuterCornerAndBackOut() throws {
        for mode in [PanelHideAnimation.slide, .swoop] {
            try withController(configure: { $0.hideAnimation = mode }) { controller, _, panel in
                let screen = try XCTUnwrap(controller.currentScreen)
                @MainActor func hide(_ corner: ScreenCorner) throws {
                    var hidden = false
                    _ = controller.requestHide { hidden = $0 == .hidden }
                    let checked = try samplePausedMotion(controller, try content(panel), mode: mode, hiding: true,
                                                         "\(mode) \(corner) hide") { p in
                        try assertOneShape(controller, panel, mode: mode, corner: corner, "\(mode) \(corner) hide at \(p)",
                                           keyframed: true)
                    }
                    spin(until: { hidden })
                    XCTAssertTrue(hidden, "\(mode) \(corner)")
                    XCTAssertEqual(checked.sorted(), [0.3, 0.7], "\(mode) \(corner): sampled the hide")
                }
                // The reveal grows both back out of the same point.
                @MainActor func reveal(_ corner: ScreenCorner) throws {
                    XCTAssertTrue(controller.show(on: screen, corner: corner))
                    let container = try content(panel)
                    let checked = try samplePausedMotion(controller, container, mode: mode, hiding: false,
                                                         "\(mode) \(corner) reveal") { p in
                        try assertOneShape(controller, panel, mode: mode, corner: corner, "\(mode) \(corner) reveal at \(p)",
                                           keyframed: true)
                    }
                    spin(until: { !container.isIslandStandInShown }, timeout: 2)
                    XCTAssertEqual(checked.sorted(), [0.3, 0.7], "\(mode) \(corner): sampled the reveal")
                    spin(0.05)
                    XCTAssertFalse(try content(panel).isIslandStandInShown, "\(mode) \(corner): handed back at rest")
                    XCTAssertEqual(controller.islandWindowsForTesting.presentedOpacity, 1, accuracy: 0.01, "\(mode) \(corner)")
                    XCTAssertTrue(try content(panel).motionIsAtRest, "\(mode) \(corner)")
                }
                let corners = [ScreenCorner.topRight, .bottomRight, .bottomLeft, .topLeft]
                try hide(.topRight)
                for corner in corners.dropFirst() {
                    try reveal(corner)
                    try hide(corner)
                }
                try reveal(.topRight)
            }
        }
    }

    /// Every frame Core Animation draws of a Swoop hide and reveal (the
    /// run paused and scanned through its whole duration, so no frame is
    /// missed and a slow host can't skip the worst one) keeps the panel and
    /// the island on Swoop's curve about the island's outer corner. Its
    /// matrix interpolation between keyframes leaves the curve where a step
    /// covers much progress: with 30 frames the drawn panel strayed by up
    /// to 37 pt mid-reveal (Astra U1); the frames are dense enough now.
    func testEverySwoopFrameKeepsThePanelAndTheIslandOnTheCurve() throws {
        try withController(configure: { $0.hideAnimation = .swoop }) { controller, _, panel in
            let screen = try XCTUnwrap(controller.currentScreen)
            let container = try content(panel)
            func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
            @MainActor func motionLayer() -> CALayer? {
                container.subviews.compactMap(\.layer).first { $0.animation(forKey: "attic.panel.swoop") != nil }
            }
            @MainActor func scan(_ note: String, corner: ScreenCorner) throws {
                let layer = try XCTUnwrap(motionLayer(), note)
                let group = try XCTUnwrap(layer.animation(forKey: "attic.panel.swoop"), note)
                let surface = local(panel.visibleContentFrame, in: panel)
                let anchor = islandAnchor(panel, corner)
                let capsule = local(L.islandFrame(panelFrame: panel.visibleContentFrame, corner: corner, spot: standing), in: panel)
                let panelCorners = corners(surface), island = corners(capsule)
                let curve = (0...800).map { step in
                    PanelSwoopGeometry.transform(progress: Double(step) / 800, visibleBounds: surface,
                                                 hostBounds: container.bounds, layerAnchor: .zero, corner: corner, anchor: anchor)
                }
                layer.speed = 0
                defer { layer.speed = 1; layer.timeOffset = 0 }
                var worst = (t: 0.0, panel: CGFloat(0), island: CGFloat(0))
                for step in 0...240 {
                    let t = Double(step) / 240
                    layer.timeOffset = group.beginTime + group.duration * t
                    CATransaction.flush()
                    let drawnPanel = panelCorners.map { container.drawnPoint($0) }
                    let drawnIsland = island.map { container.drawnPoint($0) }
                    let best = curve.map { transform in
                        (transform, zip(panelCorners, drawnPanel)
                            .map { distance(PanelSwoopGeometry.project($0, transform), $1) }.max() ?? 0)
                    }.min { $0.1 < $1.1 }!
                    let islandError = zip(island, drawnIsland)
                        .map { distance(PanelSwoopGeometry.project($0, best.0), $1) }.max() ?? 0
                    if max(best.1, islandError) > max(worst.panel, worst.island) { worst = (t, best.1, islandError) }
                }
                // Measured after the fix: at most 1.9 pt (the curve's own
                // 1/800 steps included); before it, 13 pt hiding, 37 pt
                // revealing.
                XCTAssertLessThan(worst.panel, 3, "\(note): the panel on the curve (\(worst))")
                XCTAssertLessThan(worst.island, 3, "\(note): the island on it with the panel (\(worst))")
            }
            @MainActor func hide(_ corner: ScreenCorner) throws {
                var hidden = false
                _ = controller.requestHide { hidden = $0 == .hidden }
                spin(until: { motionLayer() != nil || hidden }, timeout: 1)
                try scan("hide \(corner)", corner: corner)
                spin(until: { hidden })
                XCTAssertTrue(hidden, "hide \(corner)")
            }
            @MainActor func reveal(_ corner: ScreenCorner) throws {
                XCTAssertTrue(controller.show(on: screen, corner: corner))
                spin(until: { motionLayer() != nil }, timeout: 1)
                try scan("reveal \(corner)", corner: corner)
                spin(until: { !container.isIslandStandInShown })
                XCTAssertFalse(container.isIslandStandInShown, "reveal \(corner): handed back at rest")
            }
            try hide(.topRight)
            for corner in [ScreenCorner.bottomRight, .bottomLeft, .topLeft, .topRight] {
                try reveal(corner)
                spin(0.05)
                try hide(corner)
            }
        }
    }

    /// The dismissing swipe: under the fingers the island goes with the
    /// panel's collapse on the same transform (Slide and Swoop), and it
    /// springs back with the panel on release.
    func testTheSwipeMovesTheIslandWithThePanelAndSpringsBackWithIt() throws {
        for mode in [PanelHideAnimation.slide, .swoop] {
            try withController(configure: { $0.hideAnimation = mode }) { controller, _, panel in
                let windows = controller.islandWindowsForTesting
                panel.onTrackpadDismissProgress?(120)
                spin(0.05)
                let collapse = controller.displayedProgressForProbe
                XCTAssertGreaterThan(collapse, 0.05, "\(mode): the fingers collapse it")
                try assertOneShape(controller, panel, mode: mode, corner: .topRight, "\(mode) swipe", presented: false)
                XCTAssertEqual(windows.shownAlpha, CGFloat(1 - collapse), accuracy: 0.02, "\(mode): the island still counts as shown")
                panel.onTrackpadDismissCancelled?()
                spin(until: { !((try? self.content(panel))?.isIslandStandInShown ?? true) })
                spin(0.05)
                XCTAssertEqual(windows.presentedOpacity, 1, accuracy: 0.01, "\(mode): back with the panel")
                XCTAssertTrue(try content(panel).motionIsAtRest, "\(mode)")
            }
        }
    }

    /// Reduce Motion: the panel and the island fade together, in place.
    func testUnderReduceMotionThePanelAndTheIslandFadeTogether() throws {
        try withController(configure: { $0.hideAnimation = .swoop }) { controller, _, panel in
            AtticMotionPreference.systemReduceMotionOverride = true
            AtticTransparencySeam.systemOverride = true
            let container = try content(panel)
            let windows = controller.islandWindowsForTesting
            let capsule = local(windows.islandFrame, in: panel)
            @MainActor func assertFadingTogether(_ note: String) {
                XCTAssertTrue(container.isIslandStandInShown, "\(note): the island fades in the panel's layer")
                XCTAssertEqual(windows.island.contentView?.layer?.opacity ?? 1, 0, "\(note)")
                let opacity = container.motionOpacity()
                XCTAssertGreaterThan(opacity, 0.03, "\(note): fading (\(opacity))")
                XCTAssertLessThan(opacity, 0.97, "\(note): fading (\(opacity))")
                for point in corners(capsule) {
                    let drawn = container.drawnPoint(point)
                    XCTAssertEqual(drawn.x, point.x, accuracy: 0.5, "\(note): in place")
                    XCTAssertEqual(drawn.y, point.y, accuracy: 0.5, "\(note): in place")
                }
            }
            var hidden = false
            _ = controller.requestHide { hidden = $0 == .hidden }
            spin(0.07)
            assertFadingTogether("hide")
            spin(until: { hidden })
            let screen = try XCTUnwrap(controller.currentScreen)
            XCTAssertTrue(controller.show(on: screen, corner: .topRight))
            spin(0.07)
            assertFadingTogether("reveal")
            spin(until: { !container.isIslandStandInShown })
            spin(0.05)
            XCTAssertEqual(windows.presentedOpacity, 1, accuracy: 0.01)
        }
    }

    /// Genie: the island goes through the funnel with the panel. Its
    /// stand-in is in the snapshot, and the funnel's mouth ends at the
    /// island's outer corner.
    func testGenieTakesTheIslandThroughTheFunnelIntoItsOuterCorner() throws {
        for reduceTransparency in [false, true] {
            try withController(configure: { $0.hideAnimation = .genieLiveGlass }) { controller, _, panel in
                AtticTransparencySeam.systemOverride = reduceTransparency
                let container = try content(panel)
                // Genie's reveal (0.8 s) has ended: the windows are the island.
                spin(until: { !container.isIslandStandInShown })
                spin(0.2)
                let windows = controller.islandWindowsForTesting
                container.prepareAlternateSnapshot(.genieLiveGlass, surface: nil)
                let genie = container.genieForTesting
                let note = "reduce transparency \(reduceTransparency)"
                XCTAssertFalse(container.isIslandStandInShown, "\(note): nothing changes on screen")
                // At rest (D4): the dots' capsule, end to end.
                let rest = local(windows.restFrame, in: panel)
                for point in [CGPoint(x: rest.midX, y: rest.minY + 4), CGPoint(x: rest.midX, y: rest.midY),
                              CGPoint(x: rest.midX, y: rest.maxY - 4)] {
                    let alpha = try XCTUnwrap(genie.snapshotAlpha(around: point), note)
                    XCTAssertGreaterThan(alpha, 60, "\(note): the resting island at \(point) is in the snapshot")
                }
                var hidden = false
                _ = controller.requestHide { hidden = $0 == .hidden }
                spin(0.03)
                XCTAssertTrue(container.isIslandStandInShown, "\(note)")
                XCTAssertEqual(windows.island.contentView?.layer?.opacity ?? 1, 0, "\(note): the windows are empty")
                let anchor = islandAnchor(panel, .topRight)
                let box = container.bounds
                XCTAssertEqual(CGFloat(genie.anchorInset.x), (box.maxX - anchor.x) / box.width, accuracy: 0.001, note)
                XCTAssertEqual(CGFloat(genie.anchorInset.y), (box.maxY - anchor.y) / box.height, accuracy: 0.001, note)
                spin(until: { hidden })
                XCTAssertTrue(hidden, note)
            }
        }
    }

    /// Genie hiding in one corner and revealing in another (same panel
    /// size): the snapshot the reveal flies holds the island at the new
    /// corner and nothing at the old one, whether it is taken at the reveal
    /// (cold) or was prepared while hidden at the old corner (warm). Astra U2.
    func testAGenieRevealInANewCornerSnapshotsTheIslandThere() throws {
        for (reduceTransparency, warm) in [(false, false), (false, true), (true, true)] {
            try withController(configure: { $0.hideAnimation = .genieLiveGlass }) { controller, _, panel in
                AtticTransparencySeam.systemOverride = reduceTransparency
                let screen = try XCTUnwrap(controller.currentScreen)
                let container = try content(panel)
                let genie = container.genieForTesting
                spin(until: { !container.isIslandStandInShown })
                @MainActor func items(_ corner: ScreenCorner) -> [CGPoint] {
                    // A reveal shows the island at rest (D4): its dots' capsule.
                    let island = L.islandFrame(panelFrame: panel.visibleContentFrame, corner: corner, spot: standing)
                    let rest = local(L.restFrame(island: island, corner: corner, spot: standing), in: panel)
                    return [CGPoint(x: rest.midX, y: rest.midY)]
                }
                var from = ScreenCorner.topRight
                for to in [ScreenCorner.bottomRight, .bottomLeft, .topLeft, .topRight] {
                    let note = "reduce transparency \(reduceTransparency), \(warm ? "warm" : "cold"), \(from) to \(to)"
                    var hidden = false
                    _ = controller.requestHide { hidden = $0 == .hidden }
                    spin(until: { hidden })
                    XCTAssertTrue(hidden, note)
                    let size = panel.visibleContentFrame.size
                    let old = items(from)
                    // An expected reveal prepares the snapshot while hidden.
                    if warm { container.prepareAlternateSnapshot(.genieLiveGlass, surface: nil) }
                    XCTAssertTrue(controller.show(on: screen, corner: to), note)
                    XCTAssertEqual(panel.visibleContentFrame.size, size, "\(note): the same size")
                    for (index, point) in items(to).enumerated() {
                        let alpha = try XCTUnwrap(genie.snapshotAlpha(around: point), note)
                        XCTAssertGreaterThan(alpha, 60, "\(note): item \(index) at the new corner")
                    }
                    for (index, point) in old.enumerated() {
                        let alpha = try XCTUnwrap(genie.snapshotAlpha(around: point), note)
                        XCTAssertLessThan(alpha, 20, "\(note): nothing where item \(index) was")
                    }
                    spin(until: { !container.isIslandStandInShown })
                    XCTAssertFalse(container.isIslandStandInShown, "\(note): handed back at rest")
                    from = to
                }
            }
        }
    }

    /// No flash at a swap (motion start, reveal end, spring-back end): just
    /// before and just after it, the island's region draws the same, with
    /// the stand-in showing the same page, chip and look, and no label.
    func testTheSwapsBetweenTheIslandAndItsStandInShowNoChange() throws {
        try withController { controller, _, panel in
            // Off-screen glass renders as artefacts: compare the flat look.
            AtticTransparencySeam.systemOverride = true
            spin(0.3)
            let container = try content(panel)
            let windows = controller.islandWindowsForTesting
            var looks: [(after: Bool, toMotion: Bool, pixels: [UInt8])] = []
            var failures: [String] = []
            controller.islandSwapProbe = { after, toMotion in
                MainActor.assumeIsolated {
                    if !container.motionIsAtRest { failures.append("motion not at rest at a swap (\(after), \(toMotion))") }
                    if self.local(windows.standIn.frame, in: panel, toScreen: true) != windows.island.frame {
                        failures.append("stand-in \(windows.standIn.frame) off the island window \(windows.island.frame)")
                    }
                    if after, toMotion, (windows.label.contentView?.layer?.opacity ?? 1) != 0 { failures.append("a label shows") }
                    do { looks.append((after, toMotion, try self.islandRegion(windows, container))) } catch {
                        failures.append("\(error)")
                    }
                }
            }
            defer { controller.islandSwapProbe = nil }
            var hidden = false
            _ = controller.requestHide { hidden = $0 == .hidden }
            spin(until: { hidden })
            let screen = try XCTUnwrap(controller.currentScreen)
            XCTAssertTrue(controller.show(on: screen, corner: .topRight))
            spin(until: { !container.isIslandStandInShown })
            panel.onTrackpadDismissProgress?(100)
            spin(0.05)
            panel.onTrackpadDismissCancelled?()
            spin(until: { !container.isIslandStandInShown })
            XCTAssertEqual(failures, [])
            XCTAssertEqual(looks.map { "\($0.toMotion ? "in" : "out")\($0.after ? "+" : "-")" },
                           ["in-", "in+", "out-", "out+", "in-", "in+", "out-", "out+"],
                           "hide start, reveal end, swipe start, spring-back end")
            for pair in stride(from: 0, to: looks.count - 1, by: 2) {
                let before = looks[pair].pixels, after = looks[pair + 1].pixels
                XCTAssertEqual(before.count, after.count)
                let differences = zip(before, after).map { abs(Int($0) - Int($1)) }
                let largest = differences.max() ?? 0
                let mean = Double(differences.reduce(0, +)) / Double(max(1, differences.count))
                print(String(format: "ISLAND_SWAP %d largest=%d mean=%.4f", pair / 2, largest, mean))
                XCTAssertLessThanOrEqual(largest, 24, "swap \(pair / 2): largest channel change \(largest)")
                XCTAssertLessThan(mean, 1.0, "swap \(pair / 2): mean change \(mean)")
                XCTAssertGreaterThan(before.enumerated().filter { $0.offset % 4 == 3 }.map(\.element).max() ?? 0, 100,
                                     "swap \(pair / 2): the island is drawn")
            }
        }
    }

    // MARK: Active glass (owner, 1 Nov: the island drew inactive glass while Attic was focused)

    /// The island windows draw active exactly while their parent is key,
    /// whatever their own key state (they are never key).
    /// Key-window lane only: the invisible host freezes every window's
    /// `isKeyWindow` override to false.
    func testTheIslandWindowsDrawActiveExactlyWhileTheirParentIsKey() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ATTIC_KEY_WINDOW_TESTS"] == "1", "needs a key window")
        final class ReportsKey: NSWindow { var key = true; override var isKeyWindow: Bool { key } }
        let parent = ReportsKey(contentRect: TestPresentationPolicy.offscreenFrame(CGRect(x: 0, y: 0, width: 80, height: 80)),
                                styleMask: [.borderless], backing: .buffered, defer: true)
        parent.isReleasedWhenClosed = false
        let island = PanelIslandWindow(contentRect: TestPresentationPolicy.offscreenFrame(CGRect(x: 0, y: 0, width: 40, height: 40)),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        island.isReleasedWhenClosed = false
        func active() -> Bool? { (island.value(forKey: "_hasActiveAppearance") as? NSNumber)?.boolValue }
        XCTAssertEqual(active(), false, "alone: inactive")
        parent.addChildWindow(island, ordered: .above)
        defer { parent.removeChildWindow(island) }
        XCTAssertEqual(active(), true, "the parent is key: active")
        parent.key = false
        XCTAssertEqual(active(), false, "the parent resigned: inactive")
        XCTAssertFalse(island.isKeyWindow)
        XCTAssertFalse(island.canBecomeMain)
    }

    /// Owner, 3 Nov: a corner reveal and pointer wake must have active glass
    /// before any click, including while another app owns the keyboard.
    func testCornerRevealRequestsActiveGlassWithoutTakingTheKeyboard() throws {
        try withController { controller, state, panel in
            XCTAssertFalse(state.isPanelKey)
            XCTAssertFalse(panel.isKeyWindow)
            let active = NSRunningApplication.current.isActive
            for page in PanelPage.allCases {
                state.selectSection(page.section)
                spin(0.3)
                let responder = panel.firstResponder
                state.island.wake()
                spin(0.3)
                XCTAssertTrue(panel._hasActiveAppearance(), "\(page): native glass must be active before a click")
                XCTAssertTrue(controller.islandWindowsForTesting.island._hasActiveAppearance())
                XCTAssertTrue(controller.islandWindowsForTesting.label._hasActiveAppearance())
                XCTAssertFalse(panel.isKeyWindow)
                XCTAssertFalse(state.isPanelKey, "solid/glass chrome's key policy is independent")
                XCTAssertTrue(panel.firstResponder === responder)
                XCTAssertEqual(NSRunningApplication.current.isActive, active)
            }
        }
    }

    /// Native glass stays active as keyboard focus and app activation change.
    func testTheIslandsGlassStaysActiveWithAndWithoutThePanelsKeyboard() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ATTIC_KEY_WINDOW_TESTS"] == "1", "needs a key window")
        try withController { controller, _, panel in
            let windows = controller.islandWindowsForTesting
            // Awake, the first name shows after 400 ms (D4, L8).
            windows.model.wake()
            windows.model.point(at: PanelIslandLayout.pages[0])
            spin(PanelIslandLayout.labelDelay + 0.1)
            let other = makeOtherKeyWindow()
            defer { other.orderOut(nil) }
            @MainActor func assertGlass(active: Bool, _ note: String, file: StaticString = #filePath, line: UInt = #line) throws {
                spin(0.4)
                let island = glassStates(in: try XCTUnwrap(windows.island.contentView))
                let label = glassStates(in: try XCTUnwrap(windows.label.contentView))
                let own = glassStates(in: try XCTUnwrap(panel.contentView))
                XCTAssertFalse(island.isEmpty, "\(note): the island is glass", file: file, line: line)
                XCTAssertFalse(label.isEmpty, "\(note): the label is glass", file: file, line: line)
                XCTAssertTrue(own.contains(active), "\(note): the panel's own glass is \(active ? "active" : "inactive")",
                              file: file, line: line)
                XCTAssertEqual(Set(island), [active], "\(note): the island's glass", file: file, line: line)
                XCTAssertEqual(Set(label), [active], "\(note): the label's glass", file: file, line: line)
                XCTAssertFalse(windows.island.isKeyWindow, "\(note): the island is never key", file: file, line: line)
                XCTAssertFalse(windows.label.isKeyWindow, "\(note): the label is never key", file: file, line: line)
            }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKey()
            spin(until: { panel.isKeyWindow })
            let responder = panel.firstResponder
            try assertGlass(active: true, "the panel is key")
            XCTAssertTrue(NSApp.keyWindow === panel, "the keyboard stays with the panel")
            XCTAssertTrue(panel.firstResponder === responder, "and its focus does not move")

            other.makeKey()
            spin(until: { !panel.isKeyWindow })
            try assertGlass(active: true, "another window is key")

            panel.makeKey()
            spin(until: { panel.isKeyWindow })
            try assertGlass(active: true, "the panel is key again")

            var hidden = false
            _ = controller.requestHide { hidden = $0 == .hidden }
            spin(until: { hidden })
            let screen = try XCTUnwrap(controller.currentScreen)
            XCTAssertTrue(controller.show(on: screen, corner: .topRight, makeKey: true))
            spin(until: { panel.isKeyWindow && !((try? self.content(panel).isIslandStandInShown) ?? true) })
            // The hide settled it: the pointer wakes it again.
            windows.model.wake()
            windows.model.point(at: PanelIslandLayout.pages[0])
            spin(PanelIslandLayout.labelDelay + 0.1)
            try assertGlass(active: true, "shown again, key")
            XCTAssertTrue(NSApp.keyWindow === panel, "the keyboard stays with the panel")

            NSApp.deactivate()
            spin(until: { !panel.isKeyWindow })
            try assertGlass(active: true, "Attic deactivated")
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKey()
            spin(until: { panel.isKeyWindow })
            try assertGlass(active: true, "Attic active again")
        }
    }

    /// The stand-in (in the panel's own window) and the island window draw
    /// the same glass state at every swap, key and not key.
    func testTheStandInAndTheIslandDrawTheSameGlassStateAtEverySwap() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ATTIC_KEY_WINDOW_TESTS"] == "1", "needs a key window")
        try withController { controller, _, panel in
            let windows = controller.islandWindowsForTesting
            let container = try content(panel)
            let other = makeOtherKeyWindow()
            defer { other.orderOut(nil) }
            var seen: [String] = []
            controller.islandSwapProbe = { after, toMotion in
                MainActor.assumeIsolated {
                    guard let live = windows.island.contentView else { return }
                    let island = Set(self.glassStates(in: live)).map(String.init).sorted()
                    let standIn = Set(self.glassStates(in: windows.standIn)).map(String.init).sorted()
                    seen.append("\(toMotion ? "in" : "out")\(after ? "+" : "-") key=\(panel.isKeyWindow) island=\(island) standIn=\(standIn)")
                }
            }
            defer { controller.islandSwapProbe = nil }
            let screen = try XCTUnwrap(controller.currentScreen)
            for key in [true, false] {
                NSApp.activate(ignoringOtherApps: true)
                if key { panel.makeKey() } else { other.makeKey() }
                spin(until: { panel.isKeyWindow == key })
                spin(0.3)
                var hidden = false
                _ = controller.requestHide { hidden = $0 == .hidden }
                spin(until: { hidden })
                XCTAssertTrue(controller.show(on: screen, corner: .topRight, makeKey: key))
                spin(until: { !container.isIslandStandInShown && panel.isKeyWindow == key })
            }
            XCTAssertEqual(seen.count, 8, "\(seen)")
            for (index, entry) in seen.enumerated() {
                XCTAssertTrue(entry.hasSuffix("island=[\"true\"] standIn=[\"true\"]"), "swap \(index): \(entry)")
            }
        }
    }

    /// A window that can take key from the panel without activating Attic's panel.
    private func makeOtherKeyWindow() -> NSWindow {
        final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }
        let window = KeyPanel(contentRect: CGRect(x: 40, y: 40, width: 80, height: 80),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    /// Each live glass in `view`, active or not. AppKit's glass shows its
    /// vibrant layer (a `vibrantColorMatrix` layer) at full opacity only in
    /// a window that draws active, and at 0 otherwise (measured, macOS 26.4).
    private func glassStates(in view: NSView) -> [Bool] {
        func walk(_ layer: CALayer) -> [Bool] {
            let vibrant = (layer.filters ?? []).contains { ($0 as? NSObject)?.value(forKey: "name") as? String == "vibrantColorMatrix" }
            return (vibrant ? [layer.opacity > 0.5] : []) + (layer.sublayers ?? []).flatMap(walk)
        }
        guard let layer = view.layer else { return [] }
        return walk(layer)
    }

    // MARK: Helpers (one shape)

    private func content(_ panel: AtticPanel) throws -> AtticPanelContentContainer {
        try XCTUnwrap(panel.contentView as? AtticPanelContentContainer)
    }

    /// `rect` from screen points to the panel window's (or back).
    private func local(_ rect: CGRect, in panel: AtticPanel, toScreen: Bool = false) -> CGRect {
        toScreen ? rect.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
            : rect.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
    }

    private func corners(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
    }

    /// The island's outer corner on `corner`'s side, in the panel window's points.
    private func islandAnchor(_ panel: AtticPanel, _ corner: ScreenCorner) -> CGPoint {
        // L3 moves the island in from the panel's end: the anchor is the
        // corner of the two together (`PanelIslandLayout.collapseAnchor`).
        let point = L.collapseAnchor(panelFrame: panel.visibleContentFrame, corner: corner, spot: standing)
        return CGPoint(x: point.x - panel.frame.minX, y: point.y - panel.frame.minY)
    }

    /// The island is drawn by its stand-in (the windows are empty), over the
    /// island window, by the panel's own motion about the island's outer
    /// corner: Slide's scale, or Swoop's transform with that anchor.
    private func assertOneShape(_ controller: AtticPanelController, _ panel: AtticPanel, mode: PanelHideAnimation,
                                corner: ScreenCorner, _ note: String, presented: Bool = true, keyframed: Bool = false,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let container = try content(panel)
        let windows = controller.islandWindowsForTesting
        XCTAssertTrue(container.isIslandStandInShown, "\(note): the stand-in draws the island", file: file, line: line)
        XCTAssertEqual(windows.island.contentView?.layer?.opacity ?? 1, 0, "\(note): the window is empty", file: file, line: line)
        let surface = local(panel.visibleContentFrame, in: panel)
        let capsule = local(L.islandFrame(panelFrame: panel.visibleContentFrame, corner: corner, spot: standing), in: panel)
        let standIn = windows.standIn.frame
        let margin = L.windowMargin
        XCTAssertEqual(standIn.minX, capsule.minX - margin, accuracy: 0.5, "\(note): over the island", file: file, line: line)
        XCTAssertEqual(standIn.minY, capsule.minY - margin, accuracy: 0.5, "\(note): over the island", file: file, line: line)
        let anchor = islandAnchor(panel, corner)
        let island = corners(capsule), panelCorners = corners(surface)
        let drawnIsland = island.map { container.drawnPoint($0, presented: presented) }
        let drawnPanel = panelCorners.map { container.drawnPoint($0, presented: presented) }
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        switch mode {
        case .slide:
            let scale = (drawnPanel[1].x - drawnPanel[0].x) / surface.width
            XCTAssertLessThan(scale, 0.97, "\(note): collapsing", file: file, line: line)
            let fixed = container.drawnPoint(anchor, presented: presented)
            XCTAssertLessThan(distance(fixed, anchor), 0.75, "\(note): the island's corner stays put (\(fixed) vs \(anchor))",
                              file: file, line: line)
            for (point, drawn) in zip(island + panelCorners, drawnIsland + drawnPanel) {
                let expected = CGPoint(x: anchor.x + scale * (point.x - anchor.x), y: anchor.y + scale * (point.y - anchor.y))
                XCTAssertLessThan(distance(drawn, expected), 0.75, "\(note): \(point) scaled about the island's corner",
                                  file: file, line: line)
            }
        case .swoop:
            let host = container.bounds
            func expected(_ p: Double) -> CATransform3D {
                PanelSwoopGeometry.transform(progress: p, visibleBounds: surface, hostBounds: host, layerAnchor: .zero,
                                             corner: corner, anchor: anchor)
            }
            // The progress the panel is drawn at, then the island at it.
            var best = (p: 0.0, error: CGFloat.greatestFiniteMagnitude)
            for step in 0...500 {
                let p = Double(step) / 500
                let transform = expected(p)
                let error = zip(panelCorners, drawnPanel).map { distance(PanelSwoopGeometry.project($0, transform), $1) }.max() ?? 0
                if error < best.error { best = (p, error) }
            }
            // A timed run draws Core Animation's keyframes, interpolated
            // between, dense enough to stay within 2 pt of the curve
            // (`testEverySwoopFrameKeepsThePanelAndTheIslandOnTheCurve`).
            // The swipe checks the exact curve (1.5 pt).
            let tolerance: CGFloat = keyframed ? 3 : 1.5
            XCTAssertLessThan(best.error, tolerance, "\(note): the panel is Swoop about the island's corner (\(best))",
                              file: file, line: line)
            // Mid-flight. A timed run's presentation runs a frame or two
            // behind the run's clock (CI: drawn at 0.994 when the clock said
            // 0.69 on a reveal's fast start), so only the swipe asks this.
            if !keyframed {
                XCTAssertGreaterThan(best.p, 0.02, "\(note)", file: file, line: line)
                XCTAssertLessThan(best.p, 0.98, "\(note)", file: file, line: line)
            }
            let transform = expected(best.p)
            for (point, drawn) in zip(island, drawnIsland) {
                XCTAssertLessThan(distance(drawn, PanelSwoopGeometry.project(point, transform)), tolerance,
                                  "\(note): the island goes with it", file: file, line: line)
            }
        case .genieLiveGlass:
            XCTFail("Genie draws a mesh", file: file, line: line)
        }
    }

    /// What the island's region draws now: the island window's content and
    /// the stand-in (each rendered opaque, then weighted by its own opacity
    /// in its window), premultiplied RGBA at 2x.
    private func islandRegion(_ windows: PanelIslandWindows, _ container: AtticPanelContentContainer) throws -> [UInt8] {
        let live = try XCTUnwrap(windows.island.contentView)
        let liveOpacity = CGFloat(live.layer?.opacity ?? 1) * windows.island.alphaValue
        let standInOpacity = CGFloat(windows.standIn.layer?.opacity ?? 0) * CGFloat(container.motionOpacity(presented: false))
        let a = try opaquePixels(live), b = try opaquePixels(windows.standIn)
        XCTAssertEqual(a.count, b.count)
        return zip(a, b).map { UInt8(min(255, (CGFloat($0) * liveOpacity + CGFloat($1) * standInOpacity).rounded())) }
    }

    private func opaquePixels(_ view: NSView) throws -> [UInt8] {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let layer = view.layer
        let opacity = layer?.opacity ?? 1
        layer?.opacity = 1
        defer {
            layer?.opacity = opacity
            CATransaction.commit()
        }
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = try XCTUnwrap(rep.cgImage)
        let width = Int((view.bounds.width * 2).rounded()), height = Int((view.bounds.height * 2).rounded())
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        data.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return data
    }

    // MARK: Helpers

    private func withController(configure: (AppSettings) -> Void = { _ in },
                                _ body: @MainActor (AtticPanelController, PanelUIState, AtticPanel) throws -> Void) throws {
        // GitHub's runners turn both on; these tests state them.
        AtticMotionPreference.systemReduceMotionOverride = false
        AtticTransparencySeam.systemOverride = false
        defer {
            AtticMotionPreference.systemReduceMotionOverride = nil
            AtticTransparencySeam.systemOverride = nil
        }
        let suite = "PanelIsland.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        let notes = trackAttachmentReconciliation(of: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()))
        let state = PanelUIState()
        let settings = AppSettings(defaults: defaults)
        settings.islandSpot = standing
        configure(settings)
        let existing = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let controller = AtticPanelController(
            store: store, noteStore: notes, canvasSession: CanvasSession(store: CanvasStore(container: container)),
            noteDraft: NoteDraftController(noteStore: notes), settings: settings, uiState: state
        )
        let panel = try XCTUnwrap(NSApplication.shared.windows.compactMap { $0 as? AtticPanel }
            .first { !existing.contains(ObjectIdentifier($0)) })
        // SwiftUI builds its accessibility tree for an assistive client.
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let screen = try XCTUnwrap(controller.currentScreen ?? NSScreen.main)
        XCTAssertTrue(controller.show(on: screen, corner: .topRight))
        spin(0.8)
        defer {
            var hidden = false
            _ = controller.requestHide { hidden = $0 == .hidden }
            spin(until: { hidden })
            panel.orderOut(nil)
        }
        try body(controller, state, panel)
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

/// Samples a timed hide or reveal on the frames Core Animation draws where
/// its progress passes 0.3 and 0.7: the motion layer's run is paused and
/// stepped through its duration (as
/// `testEverySwoopFrameKeepsThePanelAndTheIslandOnTheCurve`), so a slow
/// host can neither skip a sample nor hand one a frame it has not drawn
/// yet. In real time CI 41274121451 presented a Swoop reveal in the top
/// left still at the bottom-left hide's last frame (exactly, at opacity 0)
/// while the run's clock passed 0.70 and 0.29, and passed a Slide hide's
/// 0.7 between two samples. Returns the fractions sampled.
@MainActor
func samplePausedMotion(_ controller: AtticPanelController, _ container: AtticPanelContentContainer,
                        mode: PanelHideAnimation, hiding: Bool, _ note: String,
                        file: StaticString = #filePath, line: UInt = #line,
                        _ check: (Double) throws -> Void) throws -> [Double] {
    let key = mode == .swoop ? "attic.panel.swoop" : "attic.panel.collapse"
    func running() -> (CALayer, CAAnimation)? {
        for layer in container.subviews.compactMap(\.layer) {
            if let animation = layer.animation(forKey: key) { return (layer, animation) }
        }
        return nil
    }
    let deadline = Date().addingTimeInterval(1)
    while running() == nil, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.003)) }
    guard let (layer, animation) = running() else {
        XCTFail("\(note): no timed motion", file: file, line: line)
        return []
    }
    layer.speed = 0
    defer { layer.speed = 1; layer.timeOffset = 0 }
    var checked: [Double] = []
    let steps = 240
    for step in 0...steps {
        let fraction = Double(step) / Double(steps)
        layer.timeOffset = animation.beginTime + animation.duration * fraction
        CATransaction.flush()
        let p = mode == .swoop ? (container.swoopProgressForTesting(atFraction: fraction) ?? 0)
            : controller.displayedProgressForProbe
        let due = (hiding ? [0.3, 0.7] : [0.7, 0.3]).filter { target in
            !checked.contains(target) && (hiding ? p >= target && p < 0.97 : p <= target && p > 0.03)
        }
        for target in due {
            try check(p)
            checked.append(target)
        }
    }
    return checked
}
