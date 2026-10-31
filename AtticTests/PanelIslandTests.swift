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

    // MARK: Frame math

    private func placed(in visible: CGRect, corner: ScreenCorner) -> (panel: CGRect, island: CGRect) {
        let area = L.panelArea(in: visible, corner: corner)
        let panel = PanelGeometry.panelFrame(in: area, size: size, corner: corner)
        return (panel, L.islandFrame(panelFrame: panel, corner: corner))
    }

    private func assertPlacement(in visible: CGRect, corner: ScreenCorner, _ note: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let (panel, island) = placed(in: visible, corner: corner)
        let what = "\(corner) \(note)"
        XCTAssertEqual(island.width, 27, accuracy: 0.01, "\(what): 27 pt wide", file: file, line: line)
        XCTAssertEqual(island.height, CGFloat(99), accuracy: 0.01, "\(what): four 21 pt items", file: file, line: line)
        switch corner {
        case .topRight, .bottomRight:
            XCTAssertEqual(visible.maxX - island.maxX, 8, accuracy: 0.01, "\(what): 8 pt from the edge", file: file, line: line)
            XCTAssertEqual(island.minX - panel.maxX, 8, accuracy: 0.01, "\(what): 8 pt from the panel", file: file, line: line)
            XCTAssertEqual(visible.maxX - panel.maxX, 43, accuracy: 0.01, "\(what): the panel docks 43 pt in", file: file, line: line)
        case .topLeft, .bottomLeft:
            XCTAssertEqual(island.minX - visible.minX, 8, accuracy: 0.01, "\(what): 8 pt from the edge", file: file, line: line)
            XCTAssertEqual(panel.minX - island.maxX, 8, accuracy: 0.01, "\(what): 8 pt from the panel", file: file, line: line)
            XCTAssertEqual(panel.minX - visible.minX, 43, accuracy: 0.01, "\(what): the panel docks 43 pt in", file: file, line: line)
        }
        switch corner {
        case .topRight, .topLeft:
            XCTAssertEqual(island.maxY, panel.maxY, accuracy: 0.01, "\(what): lined up with the panel's top", file: file, line: line)
            XCTAssertEqual(visible.maxY - panel.maxY, PanelGeometry.screenInset, accuracy: 0.01, file: file, line: line)
        case .bottomRight, .bottomLeft:
            XCTAssertEqual(island.minY, panel.minY, accuracy: 0.01, "\(what): lined up with the panel's bottom", file: file, line: line)
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
        XCTAssertEqual(placed(in: dockRight, corner: .topRight).island.maxX, 1440 - 64 - 8, accuracy: 0.01,
                       "8 pt from the Dock, not from the screen's edge")
    }

    func testThePanelsAreaKeepsTheIslandsStripAndItsResizeLimitToo() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        XCTAssertEqual(L.panelArea(in: visible, corner: .topRight), CGRect(x: 0, y: 0, width: 1440 - 31, height: 875))
        XCTAssertEqual(L.panelArea(in: visible, corner: .bottomLeft), CGRect(x: 31, y: 0, width: 1440 - 31, height: 875))
        let maximum = PanelGeometry.resizeMaximumSize(in: L.panelArea(in: visible, corner: .topRight))
        XCTAssertEqual(maximum.width, 1440 - 12 - 43, "the widest panel still leaves the island its room")
        // A panel pushed against the island's side stays clear of it.
        let pushed = PanelGeometry.constrainedFrame(CGRect(x: 1300, y: 300, width: 340, height: 560),
                                                    to: L.panelArea(in: visible, corner: .topRight))
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
        let rightLabel = L.labelWindowFrame(island: island, corner: .topRight)
        XCTAssertEqual(island.minX - rightLabel.maxX, 6, accuracy: 0.01, "right corners: the label sits left of the island")
        let leftLabel = L.labelWindowFrame(island: island, corner: .bottomLeft)
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
        // artefacts off screen).
        state.island.point(at: .calendar)
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
            XCTAssertEqual(windows.island.alphaValue, 1, accuracy: 0.01)
            @MainActor func assertBeside(_ corner: ScreenCorner, _ note: String) {
                let surface = controller.panelVisibleFrameForTesting
                let capsule = windows.islandFrame
                let window = windows.island.frame
                let expected = PanelIslandLayout.islandFrame(panelFrame: surface, corner: corner)
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

            // The swipe that dismisses: it goes with the panel under the fingers.
            panel.onTrackpadDismissProgress?(120)
            spin(0.05)
            XCTAssertLessThan(windows.island.alphaValue, 1, "fading with the panel's collapse")
            panel.onTrackpadDismissCancelled?()
            spin(0.8)
            XCTAssertEqual(windows.island.alphaValue, 1, accuracy: 0.01, "back with the panel")

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
            XCTAssertEqual(windows.island.alphaValue, 1, accuracy: 0.01)
            assertBeside(.bottomLeft, "docked bottom left")
        }
    }

    func testPassthroughCountsTheIsland() throws {
        try withController { controller, _, panel in
            let windows = controller.islandWindowsForTesting
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

    // MARK: Helpers

    private func withController(_ body: @MainActor (AtticPanelController, PanelUIState, AtticPanel) throws -> Void) throws {
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
        let existing = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let controller = AtticPanelController(
            store: store, noteStore: notes, canvasSession: CanvasSession(store: CanvasStore(container: container)),
            noteDraft: NoteDraftController(noteStore: notes), settings: AppSettings(defaults: defaults), uiState: state
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
