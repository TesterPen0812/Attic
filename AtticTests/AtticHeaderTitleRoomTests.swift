import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// OD-11: the header title makes room for the page switcher. Pure geometry
/// at every title length and panel width, the hosted layout the Notes page
/// uses, and the motion rules (none under Reduce Motion or Animations:
/// Reduced).
@MainActor
final class AtticHeaderTitleRoomTests: XCTestCase {
    private let panelWidths: [CGFloat] = [280, 320, 360, 420, 640]
    private let chromeInsets: [CGFloat] = [24, 28, 36]
    private let titleWidths: [CGFloat] = [0, 20, 80, 148, 260, 520, 4000]
    private let switcher = AtticPageButton<Int>.width(open: true, count: 3)

    private func placement(_ title: CGFloat, _ panel: CGFloat, _ inset: CGFloat, open: Bool) -> AtticHeaderTitleSlot.Placement {
        AtticHeaderTitleSlot.placement(titleWidth: title, panelWidth: panel, chromeInset: inset, switcherWidth: switcher, switcherOpen: open)
    }

    func testOpenSwitcherNeverCoversTheTitleAtAnyLengthAndWidth() {
        for panel in panelWidths {
            for inset in chromeInsets {
                let frame = AtticHeaderTitleSlot.switcherFrame(panelWidth: panel, chromeInset: inset, switcherWidth: switcher)
                for title in titleWidths {
                    let open = placement(title, panel, inset, open: true)
                    let label = "panel \(panel) inset \(inset) title \(title)"
                    XCTAssertLessThanOrEqual(open.maxX, frame.lowerBound - AtticHeaderTitleSlot.gap + 0.001, label)
                    XCTAssertGreaterThanOrEqual(open.x, inset + AtticControlSize.headerControl + AtticHeaderTitleSlot.gap - 0.001, label)
                    XCTAssertGreaterThanOrEqual(open.width, 0, label)
                    XCTAssertLessThanOrEqual(open.width, title + 0.001, label)
                }
            }
        }
    }

    func testOpenTitleLeftAlignsAndATitleThatFitsKeepsItsWidth() {
        let panel: CGFloat = 320, inset: CGFloat = 24
        let left = inset + AtticControlSize.headerControl + AtticHeaderTitleSlot.gap
        let short = placement(60, panel, inset, open: true)
        XCTAssertEqual(short.x, left)
        XCTAssertEqual(short.width, 60)
        // Long: it fills exactly the space the switcher leaves.
        let long = placement(4000, panel, inset, open: true)
        XCTAssertEqual(long.x, left)
        XCTAssertEqual(long.maxX, panel - inset - switcher - AtticHeaderTitleSlot.gap, accuracy: 0.001)
    }

    func testShutTitleReturnsToItsFullWidthAndTheCentre() {
        for panel in panelWidths {
            for inset in chromeInsets {
                let side = inset + AtticControlSize.headerControl + AtticHeaderTitleSlot.gap
                let room = max(0, panel - side * 2)
                for title in titleWidths {
                    let open = placement(title, panel, inset, open: true)
                    let shut = placement(title, panel, inset, open: false)
                    let label = "panel \(panel) inset \(inset) title \(title)"
                    // Shut is the title's whole width, as before this change.
                    XCTAssertEqual(shut.width, min(title, room), accuracy: 0.001, label)
                    XCTAssertEqual(shut.x + shut.width / 2, panel / 2, accuracy: 0.001, label)
                    XCTAssertGreaterThanOrEqual(shut.width, open.width - 0.001, label)
                }
            }
        }
    }

    func testRoomIsNeverNegativeInAPanelTooNarrowForTheControls() {
        for open in [true, false] {
            let p = placement(300, 100, 36, open: open)
            XCTAssertGreaterThanOrEqual(p.width, 0)
            XCTAssertTrue(p.x.isFinite)
        }
    }

    // MARK: Hosted layout

    private struct Probe: View {
        let title: String
        let open: Bool
        let panelWidth: CGFloat
        let report: (CGRect) -> Void

        var body: some View {
            AtticHeaderTitleRoom(chromeInset: 24, switcherWidth: PanelHeaderLayout.pageSwitchWidth, forcedOpen: open) {
                AtticHeaderTitle(title: title) {}
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("probe")) } action: { report($0) }
            }
            .frame(width: panelWidth, height: 60, alignment: .top)
            .coordinateSpace(name: "probe")
            .atticDesign(AtticDesignContext(reduceMotion: true))
        }
    }

    private func hostedFrame(title: String, open: Bool, panelWidth: CGFloat) -> CGRect? {
        var frame: CGRect?
        let host = NSHostingView(rootView: Probe(title: title, open: open, panelWidth: panelWidth) { frame = $0 })
        host.frame = CGRect(x: 0, y: 0, width: panelWidth, height: 60)
        host.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(2)
        while frame == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            host.layoutSubtreeIfNeeded()
        }
        return frame
    }

    func testHostedLongTitleStopsBeforeTheOpenSwitcherAndFillsTheSpaceShut() throws {
        let longTitle = String(repeating: "Network fundamentals ", count: 12)
        for panel in [320, 420] as [CGFloat] {
            let switcherLeft = AtticHeaderTitleSlot.switcherFrame(
                panelWidth: panel, chromeInset: 24, switcherWidth: PanelHeaderLayout.pageSwitchWidth).lowerBound
            let open = try XCTUnwrap(hostedFrame(title: longTitle, open: true, panelWidth: panel))
            XCTAssertLessThanOrEqual(open.maxX, switcherLeft - AtticHeaderTitleSlot.gap + 0.5, "open, panel \(panel)")
            let shut = try XCTUnwrap(hostedFrame(title: longTitle, open: false, panelWidth: panel))
            let side = 24 + AtticControlSize.headerControl + AtticHeaderTitleSlot.gap
            // The button hugs its truncated text, so it can fall a few points
            // short of the room (a word's last letter does not fit).
            let room = panel - side * 2
            XCTAssertLessThanOrEqual(shut.width, room + 0.5, "shut, panel \(panel)")
            XCTAssertGreaterThan(shut.width, room - 10, "shut, panel \(panel)")
            XCTAssertGreaterThan(shut.width, open.width, "the width comes back, panel \(panel)")
        }
    }

    func testHostedShortTitleKeepsItsWidthShutAndOpen() throws {
        let open = try XCTUnwrap(hostedFrame(title: "Notes", open: true, panelWidth: 360))
        let shut = try XCTUnwrap(hostedFrame(title: "Notes", open: false, panelWidth: 360))
        XCTAssertEqual(open.width, shut.width, accuracy: 0.5)
        XCTAssertLessThan(open.minX, shut.minX, "it slid left")
        XCTAssertEqual(shut.midX, 180, accuracy: 0.5)
    }

    // MARK: Motion

    func testReduceMotionAndReducedUseNoAnimation() {
        XCTAssertNil(AtticMotionPreset.expand.animation(reduceMotion: true))
        XCTAssertNotNil(AtticMotionPreset.expand.animation(reduceMotion: false))
        // Animations: Reduced is Reduce Motion for the design context.
        XCTAssertTrue(AtticAnimationLevel.reduced.reducesMotion(systemReduceMotion: false))
        XCTAssertTrue(AtticAnimationLevel.lively.reducesMotion(systemReduceMotion: true))
        XCTAssertFalse(AtticAnimationLevel.lively.reducesMotion(systemReduceMotion: false))
    }

    func testPresenceFlipsOnlyOnChange() {
        let presence = AtticPageSwitcherPresence()
        XCTAssertFalse(presence.isOpen)
        presence.set(true)
        XCTAssertTrue(presence.isOpen)
        presence.set(false)
        XCTAssertFalse(presence.isOpen)
    }
}
