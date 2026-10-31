import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Pull a page out, snap it back in (Planning.md, Accepted 2026-10-31
/// "Tall island: switching pages"; the design's px halved): a page dragged
/// off the island (more than 6 pt) becomes its own panel; dropped within
/// 40 pt of the island, or with its top-left corner within 40 pt of the
/// docked panel's, it docks again. The docked panel keeps one page. When
/// the docked panel hides, a pinned floating panel stays and an unpinned
/// one hides and returns with it (the user, 31 Oct).
@MainActor
final class PanelPullOutTests: XCTestCase {
    private typealias L = PanelPullOutLayout
    private let size = CGSize(width: 340, height: 560)
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)

    // MARK: Snap zones and the clamp

    func testTheSnapZonesAndTheClampInEveryCorner() {
        for corner in [ScreenCorner.topRight, .topLeft, .bottomRight, .bottomLeft] {
            let area = PanelIslandLayout.panelArea(in: visible, corner: corner)
            let home = PanelGeometry.panelFrame(in: area, size: size, corner: corner)
            let island = PanelIslandLayout.islandFrame(panelFrame: home, corner: corner)
            let far = CGRect(x: visible.midX - 170, y: visible.midY - 280, width: size.width, height: size.height)
            let what = "\(corner)"
            // The island: the pointer within 40 pt of its capsule.
            let nearIsland = CGPoint(x: PanelIslandLayout.isOnRight(corner) ? island.minX - 39 : island.maxX + 39,
                                     y: island.midY)
            XCTAssertEqual(L.snap(pointer: CGPoint(x: island.midX, y: island.midY), frame: far, island: island, home: home),
                           .island, "\(what): over the island")
            XCTAssertEqual(L.snap(pointer: nearIsland, frame: far, island: island, home: home), .island,
                           "\(what): 39 pt off the island")
            let pastIsland = CGPoint(x: island.midX, y: (PanelIslandLayout.isTop(corner) ? island.minY - 41 : island.maxY + 41))
            XCTAssertNil(L.snap(pointer: pastIsland, frame: far, island: island, home: home), "\(what): 41 pt off the island")
            // The old place: the top-left corners within 40 pt.
            let pointer = CGPoint(x: visible.midX, y: visible.midY)
            XCTAssertEqual(L.snap(pointer: pointer, frame: home.offsetBy(dx: 25, dy: -25), island: island, home: home),
                           .home, "\(what): 35 pt from its place")
            XCTAssertNil(L.snap(pointer: pointer, frame: home.offsetBy(dx: 30, dy: -30), island: island, home: home),
                         "\(what): 42 pt from its place")
            XCTAssertNil(L.snap(pointer: pointer, frame: far, island: nil, home: nil), "\(what): no docked panel, no snap")

            // The clamp: 8 pt inside the work area, past every edge of the corner.
            let beyond = home.offsetBy(dx: PanelIslandLayout.isOnRight(corner) ? 400 : -400,
                                       dy: PanelIslandLayout.isTop(corner) ? 400 : -400)
            let kept = L.clamp(beyond, to: visible)
            XCTAssertEqual(kept.size, size, "\(what): the clamp keeps the size")
            if PanelIslandLayout.isOnRight(corner) {
                XCTAssertEqual(visible.maxX - kept.maxX, 8, accuracy: 0.01, "\(what): 8 pt from the right")
            } else {
                XCTAssertEqual(kept.minX - visible.minX, 8, accuracy: 0.01, "\(what): 8 pt from the left")
            }
            if PanelIslandLayout.isTop(corner) {
                XCTAssertEqual(visible.maxY - kept.maxY, 8, accuracy: 0.01, "\(what): 8 pt below the top")
            } else {
                XCTAssertEqual(kept.minY - visible.minY, 8, accuracy: 0.01, "\(what): 8 pt above the bottom")
            }
            XCTAssertEqual(L.clamp(far, to: visible), far, "\(what): a panel inside stays where it is")
        }
        // A panel held at its top row, the pointer at the middle of it.
        let frame = L.frame(under: CGPoint(x: 500, y: 600), grab: L.grab(for: size), size: size)
        XCTAssertEqual(frame.midX, 500, accuracy: 0.01)
        XCTAssertEqual(frame.maxY - 600, 21, accuracy: 0.01, "grabbed 21 pt below its top")
    }

    func testAPressPullsOnlyAfterMoreThan6pt() {
        let island = CGRect(x: 1405, y: 764, width: 27, height: 99)
        let notes = PanelIslandLayout.itemFrame(1, in: island)
        let start = CGPoint(x: notes.midX, y: notes.midY)
        var tracker = PanelIslandPullTracker()
        XCTAssertNil(tracker.handle(.down(start), island: island))
        XCTAssertNil(tracker.handle(.dragged(CGPoint(x: start.x - 4, y: start.y - 4)), island: island), "5.7 pt: still a press")
        XCTAssertEqual(tracker.handle(.dragged(CGPoint(x: start.x - 7, y: start.y)), island: island),
                       .began(.notes, CGPoint(x: start.x - 7, y: start.y)), "7 pt: Notes comes out")
        XCTAssertEqual(tracker.handle(.dragged(CGPoint(x: 900, y: 500)), island: island), .moved(CGPoint(x: 900, y: 500)))
        XCTAssertEqual(tracker.handle(.up(CGPoint(x: 900, y: 500)), island: island), .ended(CGPoint(x: 900, y: 500)))
        // A click is never a pull, and a press off the items never pulls.
        XCTAssertNil(tracker.handle(.down(start), island: island))
        XCTAssertNil(tracker.handle(.up(start), island: island))
        XCTAssertNil(tracker.handle(.down(CGPoint(x: island.minX + 1, y: island.minY + 1)), island: island))
        XCTAssertNil(tracker.handle(.dragged(CGPoint(x: 100, y: 100)), island: island))
    }

    // MARK: The state

    func testPagesComeOutAndGoBackInAndTheDockedPanelKeepsOnePage() {
        var state = PanelPullOutState()
        state.dockedShows(.calendar)
        state.dockedShows(.notes)
        state.dockedShows(.tasks)
        XCTAssertEqual(state.fallback(for: .tasks), .notes, "the page shown before")
        XCTAssertTrue(state.pullOut(.tasks, at: CGRect(x: 100, y: 100, width: 340, height: 560)))
        XCTAssertFalse(state.pullOut(.tasks, at: .zero), "a page lives in one panel")
        XCTAssertEqual(state.fallback(for: .notes), .calendar, "skips a page that's out")
        XCTAssertTrue(state.pullOut(.notes, at: .zero))
        XCTAssertTrue(state.canPullOut(.calendar))
        XCTAssertTrue(state.pullOut(.calendar, at: .zero))
        XCTAssertFalse(state.canPullOut(.canvas), "the last page stays docked")
        XCTAssertFalse(state.pullOut(.canvas, at: .zero))
        XCTAssertEqual(state.outPages, [.tasks, .notes, .calendar])
        XCTAssertEqual(state.fallback(for: .canvas), nil)
        state.dockIn(.notes)
        XCTAssertFalse(state.isOut(.notes))
        XCTAssertTrue(state.canPullOut(.canvas))
        state.move(.tasks, to: CGRect(x: 5, y: 6, width: 340, height: 560))
        XCTAssertEqual(state.record(.tasks)?.frame.origin, CGPoint(x: 5, y: 6))
    }

    func testShortcutsAndClicksBringAPageThatsOutForward() {
        var state = PanelPullOutState()
        state.pullOut(.notes, at: .zero)
        state.pullOut(.calendar, at: .zero)
        XCTAssertEqual(state.front, .calendar, "the newest in front")
        XCTAssertEqual(state.route(for: .notes), .raise, "⌘2 with Notes out raises its panel")
        XCTAssertEqual(state.route(for: .tasks), .switchDocked, "⌘1 with Tasks in switches the docked panel")
        state.raise(.notes)
        XCTAssertEqual(state.front, .notes)
        XCTAssertEqual(state.floating.map(\.page), [.calendar, .notes], "back to front")
    }

    func testPinnedPanelsStayWhenTheDockedPanelHidesAndUnpinnedOnesGo() {
        var state = PanelPullOutState()
        state.pullOut(.notes, at: .zero)
        state.pullOut(.calendar, at: .zero, pinned: true)
        XCTAssertFalse(state.staysWhenDockedHides(.notes))
        XCTAssertTrue(state.staysWhenDockedHides(.calendar))
        XCTAssertEqual(state.hidingWithDocked, [.notes])
        state.setPinned(.notes, true)
        state.setPinned(.calendar, false)
        XCTAssertEqual(state.hidingWithDocked, [.calendar])
    }

    func testRestoreKeepsPagesFramesAndPinsOnTheScreensThereAreNow() throws {
        var saved = PanelPullOutState()
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        saved.pullOut(.notes, at: CGRect(x: 2000, y: 300, width: 340, height: 560), pinned: true)
        saved.pullOut(.calendar, at: CGRect(x: 200, y: 200, width: 340, height: 560))
        saved.pullOut(.tasks, at: CGRect(x: 1300, y: 700, width: 340, height: 560))
        let records = PanelPullOutState.decode(saved.encoded())
        XCTAssertEqual(records, saved.floating, "saved and read back")

        // Same screens: as they were (Tasks kept 8 pt inside).
        let same = PanelPullOutState.restored(records, workAreas: [visible, second])
        XCTAssertEqual(same.record(.notes)?.frame, CGRect(x: 2000, y: 300, width: 340, height: 560))
        XCTAssertEqual(same.record(.notes)?.isPinned, true)
        XCTAssertEqual(same.record(.calendar)?.frame, CGRect(x: 200, y: 200, width: 340, height: 560))

        // The second display is gone: Notes comes onto the one there is, pin kept.
        let one = PanelPullOutState.restored(records, workAreas: [visible])
        let notes = try XCTUnwrap(one.record(.notes))
        XCTAssertTrue(visible.insetBy(dx: 8, dy: 8).contains(notes.frame), "on the remaining screen")
        XCTAssertEqual(visible.maxX - notes.frame.maxX, 8, accuracy: 0.01)
        XCTAssertTrue(notes.isPinned)
        XCTAssertEqual(one.outPages, [.notes, .calendar, .tasks])
        XCTAssertTrue(visible.insetBy(dx: 8, dy: 8).contains(try XCTUnwrap(one.record(.tasks)).frame))
        // A smaller screen: the panel shrinks to fit inside it.
        let small = CGRect(x: 0, y: 0, width: 800, height: 500)
        let shrunk = try XCTUnwrap(PanelPullOutState.restored(records, workAreas: [small]).record(.calendar))
        XCTAssertTrue(small.insetBy(dx: 8, dy: 8).contains(shrunk.frame))

        // Never every page: the docked panel keeps one.
        let everything = records + [.init(page: .canvas, frame: CGRect(x: 10, y: 10, width: 340, height: 560), isPinned: false)]
        XCTAssertEqual(PanelPullOutState.restored(everything, workAreas: [visible]).outPages.count, 3)
        XCTAssertTrue(PanelPullOutState.restored([], workAreas: [visible]).floating.isEmpty)
        XCTAssertTrue(PanelPullOutState.decode(Data("junk".utf8)).isEmpty)
    }
}

/// The pull-out with real panels in the invisible test host.
@MainActor
final class PanelPullOutHostedTests: XCTestCase {
    @MainActor private struct Rig {
        let controller: AtticPanelController
        let state: PanelUIState
        let panel: AtticPanel
        let settings: AppSettings
        var island: PanelIslandWindows { controller.islandWindowsForTesting }
        var pullOut: PanelPullOutController { controller.pullOut }
        var workArea: CGRect {
            TestPresentationPolicy.placementFrame((controller.currentScreen ?? NSScreen.main!).visibleFrame)
        }
        func itemCentre(_ page: PanelPage) -> CGPoint {
            let index = PanelIslandLayout.pages.firstIndex(of: page)!
            let item = PanelIslandLayout.itemFrame(index, in: island.islandFrame)
            return CGPoint(x: item.midX, y: item.midY)
        }
    }

    func testAPullOutMakesAPanelWithThatPageAndTheDockedPanelShowsThePreviousOne() throws {
        try withRig { rig in
            rig.state.selectSection(.calendar)
            spin(0.3)
            rig.state.selectSection(.tasks)
            spin(0.3)
            let start = rig.itemCentre(.tasks)
            let drop = CGPoint(x: rig.workArea.midX - 200, y: rig.workArea.midY + 100)
            rig.island.handlePointer(.down(start))
            rig.island.handlePointer(.dragged(CGPoint(x: start.x - 5, y: start.y)))
            XCTAssertNil(rig.pullOut.panel(for: .tasks), "5 pt is still a press")
            rig.island.handlePointer(.dragged(CGPoint(x: start.x - 10, y: start.y)))
            rig.island.handlePointer(.dragged(drop))
            rig.island.handlePointer(.up(drop))
            spin(0.6)
            let floating = try XCTUnwrap(rig.pullOut.panel(for: .tasks), "Tasks is its own panel")
            XCTAssertTrue(floating.isVisible)
            XCTAssertEqual(floating.panel.alphaValue, 1, accuracy: 0.01, "faded in")
            XCTAssertEqual(floating.uiState.selectedSection, .tasks)
            XCTAssertTrue(floating.uiState.isFloating)
            XCTAssertEqual(floating.panel.title, "Tasks", "a window named after its page")
            XCTAssertEqual(floating.visibleFrame.size, rig.panel.visibleContentFrame.size, "the docked panel's size")
            XCTAssertEqual(floating.visibleFrame.midX, drop.x, accuracy: 0.5, "under the pointer")
            XCTAssertEqual(floating.visibleFrame.maxY - drop.y, 21, accuracy: 0.5, "held at its top row")
            XCTAssertGreaterThan(floating.panel.level.rawValue, rig.panel.level.rawValue, "above the docked panel")
            XCTAssertEqual(rig.state.selectedSection, .calendar, "the docked panel shows the page before")
            XCTAssertTrue(rig.state.pagesElsewhere.contains(.tasks), "and never builds Tasks again")
            XCTAssertEqual(PanelPullOutState.decode(rig.settings.floatingPanelsData).map(\.page), [.tasks], "saved")
            // A page that isn't showing comes out too; the docked panel keeps its page.
            XCTAssertTrue(rig.pullOut.beginPull(.notes, at: drop.applying(.init(translationX: 30, y: 0))))
            rig.pullOut.endPull(at: drop.applying(.init(translationX: 30, y: 0)))
            spin(0.5)
            XCTAssertEqual(rig.pullOut.panel(for: .notes)?.uiState.selectedSection, .notes)
            XCTAssertEqual(rig.state.selectedSection, .calendar)
            XCTAssertEqual(rig.state.island.outPages, [.tasks, .notes])
        }
    }

    func testTheOutDotShowsAndAClickOrShortcutRaisesThePanel() throws {
        try withRig { rig in
            try pull(.tasks, in: rig, to: CGPoint(x: rig.workArea.midX - 300, y: rig.workArea.midY))
            try pull(.calendar, in: rig, to: CGPoint(x: rig.workArea.midX - 200, y: rig.workArea.midY - 40))
            let model = rig.state.island
            XCTAssertEqual(model.outPages, [.tasks, .calendar], "the out dots")
            XCTAssertEqual(rig.pullOut.state.front, .calendar)
            // The item still reads as a button with its page's name, and says where it is.
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            let previous = NSApp.accessibilityAttributeValue(enhanced)
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
            spin(0.3)
            let item = try XCTUnwrap(elements(rig.island.island.contentView!).first {
                ($0.accessibilityIdentifier?() ?? "") == PanelPage.tasks.accessibilityIdentifier })
            XCTAssertEqual(item.accessibilityLabel?(), "Tasks")
            XCTAssertEqual((item as? NSObject)?.perform(Selector(("accessibilityValue")))?.takeUnretainedValue() as? String,
                           "In its own panel")
            // VoiceOver's press (a click) brings its panel forward.
            XCTAssertTrue(item.accessibilityPerformPress?() ?? false)
            spin(0.2)
            XCTAssertEqual(rig.pullOut.state.front, .tasks, "a click raises Tasks")
            XCTAssertEqual(rig.state.selectedSection, .notes, "the docked panel keeps its page")
            // ⌘3 (the docked panel's switch path) raises Calendar.
            rig.state.switchPage(to: .calendar, motion: .instant)
            XCTAssertEqual(rig.pullOut.state.front, .calendar)
            XCTAssertEqual(rig.state.selectedSection, .notes)
            XCTAssertEqual(PanelPullOutState.decode(rig.settings.floatingPanelsData).last?.page, .calendar, "the stacking is saved")
        }
    }

    func testASnapBackDocksItAndShowsThePage() throws {
        try withRig { rig in
            // Onto the island.
            try pull(.tasks, in: rig, to: CGPoint(x: rig.workArea.midX - 300, y: rig.workArea.midY))
            let floating = try XCTUnwrap(rig.pullOut.panel(for: .tasks))
            let island = rig.island.islandFrame
            let near = CGPoint(x: island.minX - 30, y: island.midY)
            XCTAssertTrue(rig.pullOut.beginPull(.tasks, at: CGPoint(x: rig.workArea.midX - 300, y: rig.workArea.midY)))
            rig.pullOut.movePull(to: near)
            XCTAssertTrue(rig.state.island.isSnapTarget, "the island's blue ring")
            rig.pullOut.endPull(at: near)
            XCTAssertFalse(rig.state.island.isSnapTarget)
            spin(0.6)
            XCTAssertNil(rig.pullOut.panel(for: .tasks), "flew home")
            XCTAssertFalse(floating.isVisible)
            XCTAssertEqual(rig.state.selectedSection, .tasks, "the docked panel shows it")
            XCTAssertFalse(rig.state.pagesElsewhere.contains(.tasks))
            XCTAssertTrue(rig.state.island.outPages.isEmpty)
            XCTAssertTrue(PanelPullOutState.decode(rig.settings.floatingPanelsData).isEmpty)

            // Near its old place, by its own top row.
            try pull(.calendar, in: rig, to: CGPoint(x: rig.workArea.midX - 300, y: rig.workArea.midY))
            let calendar = try XCTUnwrap(rig.pullOut.panel(for: .calendar))
            let home = rig.panel.visibleContentFrame
            let changed = try XCTUnwrap(calendar.hostingViewForTesting.onWindowDragChanged)
            calendar.hostingViewForTesting.onWindowDragBegan?()
            let landed = changed(home.offsetBy(dx: -20, dy: -20), CGPoint(x: home.midX, y: home.maxY - 40))
            calendar.setFrame(landed)
            XCTAssertFalse(rig.state.island.isSnapTarget, "not the island")
            calendar.hostingViewForTesting.onWindowDragEnded?(landed, CGPoint(x: home.midX, y: home.maxY - 40), .zero, .zero)
            spin(0.6)
            XCTAssertNil(rig.pullOut.panel(for: .calendar), "docked again")
            XCTAssertEqual(rig.state.selectedSection, .calendar)

            // Anywhere else: it stays where it was dropped.
            try pull(.notes, in: rig, to: CGPoint(x: rig.workArea.midX - 300, y: rig.workArea.midY))
            let notes = try XCTUnwrap(rig.pullOut.panel(for: .notes))
            let away = notes.visibleFrame.offsetBy(dx: 60, dy: 50)
            notes.hostingViewForTesting.onWindowDragBegan?()
            let moved = try XCTUnwrap(notes.hostingViewForTesting.onWindowDragChanged)(away, CGPoint(x: away.midX, y: away.maxY - 21))
            notes.setFrame(moved)
            notes.hostingViewForTesting.onWindowDragEnded?(moved, CGPoint(x: away.midX, y: away.maxY - 21), .zero, .zero)
            spin(0.3)
            XCTAssertTrue(notes.isVisible, "still out")
            XCTAssertEqual(notes.visibleFrame, away, "where it was dropped")
            XCTAssertEqual(rig.pullOut.state.record(.notes)?.frame, away, "and saved there")
        }
    }

    func testAnUnpinnedPanelHidesAndReturnsWithTheDockedPanelAndAPinnedOneStays() throws {
        try withRig { rig in
            try pull(.tasks, in: rig, to: CGPoint(x: rig.workArea.midX - 300, y: rig.workArea.midY))
            try pull(.calendar, in: rig, to: CGPoint(x: rig.workArea.midX - 100, y: rig.workArea.midY - 60))
            let tasks = try XCTUnwrap(rig.pullOut.panel(for: .tasks))
            let calendar = try XCTUnwrap(rig.pullOut.panel(for: .calendar))
            calendar.uiState.isPanelPinned = true
            XCTAssertEqual(rig.pullOut.state.record(.calendar)?.isPinned, true, "its own Pin")
            XCTAssertFalse(rig.state.isPanelPinned, "the docked panel's pin is its own")
            var hidden = false
            _ = rig.controller.requestHide { hidden = $0 == .hidden }
            spin(until: { hidden })
            spin(0.5)
            XCTAssertFalse(rig.panel.isVisible)
            XCTAssertFalse(tasks.isVisible, "unpinned: hides with the docked panel")
            XCTAssertTrue(calendar.isVisible, "pinned: stays on screen")
            let screen = try XCTUnwrap(rig.controller.currentScreen)
            XCTAssertTrue(rig.controller.show(on: screen, corner: .topRight))
            spin(0.8)
            XCTAssertTrue(tasks.isVisible, "and comes back with it")
            XCTAssertEqual(tasks.panel.alphaValue, 1, accuracy: 0.01)
            XCTAssertTrue(calendar.isVisible)
        }
    }

    func testThePointerOnAFloatingPanelOrInTheGapNeverHidesTheDockedPanel() throws {
        try withRig { rig in
            try pull(.tasks, in: rig, to: CGPoint(x: rig.workArea.midX - 300, y: rig.workArea.midY))
            let floating = try XCTUnwrap(rig.pullOut.panel(for: .tasks))
            let centre = CGPoint(x: floating.visibleFrame.midX, y: floating.visibleFrame.midY)
            XCTAssertTrue(rig.controller.containsScreenPoint(centre), "a floating panel is part of the panel")
            let island = rig.island.islandFrame
            let gap = CGPoint(x: island.minX - PanelIslandLayout.panelGap / 2, y: island.midY)
            XCTAssertFalse(rig.panel.visibleContentFrame.contains(gap))
            XCTAssertTrue(rig.controller.containsScreenPoint(gap), "the 8 pt gap to the island too")
            rig.controller.updateMousePassthrough(at: gap)
            XCTAssertFalse(rig.panel.ignoresMouseEvents)
            let below = CGPoint(x: gap.x, y: island.minY - 20)
            XCTAssertFalse(rig.panel.visibleContentFrame.insetBy(dx: -1, dy: 0).contains(below))
            XCTAssertFalse(rig.controller.containsScreenPoint(below), "below the island the gap is outside")
            XCTAssertFalse(rig.controller.containsScreenPoint(CGPoint(x: floating.visibleFrame.minX - 30, y: centre.y)))
            // An editor or menu held in it holds the docked panel too.
            floating.uiState.setInteractionLock(.menuTracking, isActive: true)
            XCTAssertTrue(rig.controller.floatingInteractionLockReasons.contains(.menuTracking))
            floating.uiState.setInteractionLock(.menuTracking, isActive: false)
        }
    }

    func testSearchAndPlusStayInTheirOwnPanel() throws {
        try withRig { rig in
            rig.state.selectSection(.calendar)
            spin(0.5)
            try pull(.tasks, in: rig, to: CGPoint(x: rig.workArea.midX - 300, y: rig.workArea.midY))
            let floating = try XCTUnwrap(rig.pullOut.panel(for: .tasks))
            let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
            let previous = NSApp.accessibilityAttributeValue(enhanced)
            NSApp.accessibilitySetValue(true, forAttribute: enhanced)
            defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
            spin(1.0)
            let host = floating.hostingViewForTesting
            let docked = try XCTUnwrap((rig.panel.contentView as? AtticPanelContentContainer)?.hostingView)
            @MainActor func element(_ id: String, in view: NSView) -> AnyObject? {
                elements(view).first { ($0.accessibilityIdentifier?() ?? "") == id }
            }
            // "+" opens the card in this panel, on Tasks.
            let plus = try XCTUnwrap(element("tasks-new-task", in: host), "the floating panel's own \"+\"")
            XCTAssertTrue(plus.accessibilityPerformPress?() ?? false)
            spin(1.0)
            XCTAssertNotNil(element("composer-card", in: host), "the card opens in the floating panel")
            XCTAssertNil(element("composer-card", in: docked), "not in the docked panel")
            XCTAssertEqual(rig.state.selectedSection, .calendar)
            // Search opens in this panel only.
            let find = try XCTUnwrap(element("tasks-find-button", in: host))
            XCTAssertTrue(find.accessibilityPerformPress?() ?? false)
            spin(0.8)
            XCTAssertNotNil(element("tasks-find", in: host), "its own Search")
            XCTAssertNil(element("calendar-search", in: docked), "the docked panel's stays shut")
        }
    }

    // MARK: Helpers

    /// Pulls `page` off the island and drops it at `point`.
    private func pull(_ page: PanelPage, in rig: Rig, to point: CGPoint,
                      file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(rig.pullOut.beginPull(page, at: rig.itemCentre(page)), "\(page) comes out", file: file, line: line)
        rig.pullOut.movePull(to: point)
        rig.pullOut.endPull(at: point)
        spin(0.5)
        XCTAssertNotNil(rig.pullOut.panel(for: page), file: file, line: line)
    }

    private func withRig(_ body: @MainActor (Rig) throws -> Void) throws {
        // GitHub's runners turn both on; these tests state them.
        AtticMotionPreference.systemReduceMotionOverride = false
        AtticTransparencySeam.systemOverride = false
        defer {
            AtticMotionPreference.systemReduceMotionOverride = nil
            AtticTransparencySeam.systemOverride = nil
        }
        let suite = "PanelPullOut.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        let notes = trackAttachmentReconciliation(of: NoteStore(container: container, attachmentFileStore: makeTestAttachmentFileStore()))
        let state = PanelUIState()
        let settings = AppSettings(defaults: defaults)
        let existing = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let controller = AtticPanelController(
            store: store, noteStore: notes, canvasSession: CanvasSession(store: CanvasStore(container: container)),
            noteDraft: NoteDraftController(noteStore: notes), settings: settings, uiState: state
        )
        let panel = try XCTUnwrap(NSApplication.shared.windows.compactMap { $0 as? AtticPanel }
            .first { !existing.contains(ObjectIdentifier($0)) })
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
        try body(Rig(controller: controller, state: state, panel: panel, settings: settings))
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
