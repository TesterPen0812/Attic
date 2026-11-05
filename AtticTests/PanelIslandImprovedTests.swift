import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// "The island, improved" (Planning.md, Accepted 2026-11-03; the drawings
/// are `island-drafts.html` and `island-icons-drafts.html`): the contact
/// shadow (L4), the travelling highlight (L5), the first name waiting
/// (L8), wider items lying flat (L12), dots at rest (D4) and the new icons
/// (I5, I6). L2, L3, L12 and the eighth spot are in `PanelIslandPositionTests`.
@MainActor
final class PanelIslandImprovedTests: XCTestCase {
    private typealias L = PanelIslandLayout

    /// A clock and timer the tests step by hand.
    private final class Clock {
        var now = Date(timeIntervalSinceReferenceDate: 0)
        var pending: [(at: Date, run: () -> Void)] = []
        func schedule(_ delay: TimeInterval, _ run: @escaping () -> Void) { pending.append((now.addingTimeInterval(delay), run)) }
        func advance(_ seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
            let due = pending.filter { $0.at <= now }
            pending.removeAll { $0.at <= now }
            due.forEach { $0.run() }
        }
    }

    private func model(_ clock: Clock) -> PanelIslandModel {
        PanelIslandModel(now: { clock.now }, schedule: { clock.schedule($0, $1) })
    }

    // MARK: L4

    /// Three layers replace the single shadow: a 0.5 pt edge at 10 %,
    /// 0 1 2 pt at 16 % and 0 6 16 pt at 16 %; in Dark 60 / 50 / 50 %.
    func testTheContactShadowHasThreeLayers() {
        let light = L.contactShadow(dark: false)
        XCTAssertEqual(light.edgeWidth, 0.5)
        XCTAssertEqual(light.edgeOpacity, 0.10, accuracy: 0.001)
        XCTAssertEqual(light.layers.map(\.y), [1, 6])
        XCTAssertEqual(light.layers.map(\.blur), [2, 16])
        XCTAssertEqual(light.layers.map(\.opacity), [0.16, 0.16])
        let dark = L.contactShadow(dark: true)
        XCTAssertEqual(dark.edgeOpacity, 0.60, accuracy: 0.001)
        XCTAssertEqual(dark.layers.map(\.opacity), [0.50, 0.50])
        // The window has room for the deepest layer below the capsule.
        XCTAssertGreaterThanOrEqual(L.windowMargin, 6 + 16)
    }

    // MARK: L5

    /// The current-page chip slides from the old item to the new one on the
    /// pop spring (200 ms, bounce 0.12); under Reduce Motion it fades.
    func testTheHighlightTravelsOnThePopSpring() {
        XCTAssertEqual(L.pop, AtticMotionSpring(response: 0.2, bounce: 0.12))
        XCTAssertNotNil(L.chipAnimation(reduceMotion: false))
        XCTAssertTrue(L.chipTravels(reduceMotion: false))
        XCTAssertFalse(L.chipTravels(reduceMotion: true), "Reduce Motion: it fades")
    }

    // MARK: L8

    /// The first name shows after 400 ms; moving on to another item within
    /// 500 ms shows its name at once, as the Dock does.
    func testTheFirstNameWaitsAndTheNextShowsAtOnce() {
        let clock = Clock()
        let island = model(clock)
        island.point(at: .tasks)
        XCTAssertEqual(island.pointed, .tasks)
        XCTAssertNil(island.labelPage, "the first name waits")
        clock.advance(0.39)
        XCTAssertNil(island.labelPage)
        clock.advance(0.02)
        XCTAssertEqual(island.labelPage, .tasks, "after 400 ms")
        island.point(at: .notes)
        XCTAssertEqual(island.labelPage, .notes, "moving on: at once")
        island.leave(.notes)
        XCTAssertNil(island.labelPage)
        clock.advance(0.3)
        island.point(at: .calendar)
        XCTAssertEqual(island.labelPage, .calendar, "back within 500 ms: at once")
        island.leave(.calendar)
        clock.advance(0.6)
        island.point(at: .tasks)
        XCTAssertNil(island.labelPage, "after 500 ms away it waits again")
        island.leave(.tasks)
        clock.advance(1)
        XCTAssertNil(island.labelPage, "a wait that was left never shows")
    }

    // MARK: L12

    func testLyingFlatTheItemsAreWider() {
        let flat = L.size(spot: .acrossOpenEnd)
        XCTAssertEqual(flat, CGSize(width: 146, height: 27))
        XCTAssertEqual(L.size(spot: .screenSideMiddle), CGSize(width: 27, height: 126))
        let island = CGRect(origin: .zero, size: flat)
        XCTAssertEqual(L.itemFrame(0, in: island), CGRect(x: 3, y: 3, width: 25, height: 21))
        XCTAssertEqual(L.itemFrame(3, in: island).maxX, 112)
    }

    // MARK: D4

    /// At rest: a 13 × 43 capsule on the panel's side, one dot per page,
    /// the current one 6 pt at full ink, the others 5 pt at 32 %.
    func testAtRestTheIslandIsDotsInANarrowCapsule() {
        // Top right, screen side corner end: the panel is left of the island.
        let island = CGRect(x: 1000, y: 700, width: 27, height: 99)
        let rest = L.restFrame(island: island, corner: .topRight, spot: .screenSideCornerEnd)
        XCTAssertEqual(rest.size, CGSize(width: 13, height: 43))
        XCTAssertEqual(rest.minX, island.minX, "on the panel's side")
        XCTAssertEqual(rest.maxY, island.maxY, "at the island's top, where it lines up")
        let open = L.restFrame(island: island, corner: .topRight, spot: .openSideCornerEnd)
        XCTAssertEqual(open.maxX, island.maxX, "the open side: the panel is right of it")
        let flat = CGRect(x: 600, y: 300, width: 115, height: 27)
        let flatRest = L.restFrame(island: flat, corner: .topRight, spot: .acrossOpenEnd)
        XCTAssertEqual(flatRest.size, CGSize(width: 43, height: 13))
        XCTAssertEqual(flatRest.midX, flat.midX)
        XCTAssertEqual(flatRest.maxY, flat.maxY, "below the panel: the dots hug its edge")
        let dots = L.restDots(current: 1, count: 4)
        XCTAssertEqual(dots.map(\.diameter), [5, 6, 5, 5])
        XCTAssertEqual(dots.map(\.ink), [0.32, 1, 0.32, 0.32])
        XCTAssertEqual(dots.map(\.along), [6.5, 16.5, 26.5, 36.5], "10 pt apart in the 43 pt capsule")
        XCTAssertEqual(L.iconSize(for: .canvas), 11.5, "I6 is drawn at 11.5 pt")
        XCTAssertEqual(L.iconSize(for: .tasks), 12.2, "each dot grows into a 12.2 pt icon")
    }

    /// It wakes when the pointer comes within 16 pt, on a click, or while a
    /// page is dragged near; 300 ms after the pointer leaves it settles
    /// (Accepted 2026-11-04: quicker than D4's 800 ms).
    func testItWakesNearThePointerAndSettlesAfter300ms() {
        let clock = Clock()
        let island = model(clock)
        XCTAssertFalse(island.isAwake, "at rest when not in use")
        let rest = CGRect(x: 100, y: 100, width: 13, height: 43)
        let awake = CGRect(x: 100, y: 56, width: 27, height: 99)
        island.track(pointer: CGPoint(x: rest.minX - 17, y: rest.midY), rest: rest, awake: awake)
        XCTAssertFalse(island.isAwake, "17 pt away: still at rest")
        island.track(pointer: CGPoint(x: rest.minX - 15, y: rest.midY), rest: rest, awake: awake)
        XCTAssertTrue(island.isAwake, "within 16 pt it wakes")
        island.track(pointer: CGPoint(x: awake.maxX + 10, y: awake.minY + 5), rest: rest, awake: awake)
        XCTAssertTrue(island.isAwake, "awake, the zone is the whole island's")
        island.track(pointer: CGPoint(x: awake.maxX + 40, y: awake.midY), rest: rest, awake: awake)
        clock.advance(0.29)
        XCTAssertTrue(island.isAwake)
        clock.advance(0.02)
        XCTAssertFalse(island.isAwake, "300 ms after the pointer leaves")
        // Coming back before it settles keeps it awake.
        island.wake()
        island.track(pointer: CGPoint(x: awake.maxX + 40, y: awake.midY), rest: rest, awake: awake)
        clock.advance(0.2)
        island.track(pointer: CGPoint(x: awake.midX, y: awake.midY), rest: rest, awake: awake)
        clock.advance(1)
        XCTAssertTrue(island.isAwake)
        // A page dragged near holds it awake, whatever the pointer.
        island.setSnapTarget(true)
        island.track(pointer: CGPoint(x: awake.maxX + 40, y: awake.midY), rest: rest, awake: awake)
        clock.advance(1)
        XCTAssertTrue(island.isAwake, "the snap ring keeps it awake")
        island.setSnapTarget(false)
        clock.advance(0.31)
        XCTAssertFalse(island.isAwake)
        // A click wakes it.
        island.click(.notes)
        XCTAssertTrue(island.isAwake)
    }

    // MARK: I5, I6

    func testNotesIsAPageAndDrawIsAPencilAndScribble() {
        XCTAssertEqual(PanelPage.notes.systemName, "doc.text")
        XCTAssertEqual(PanelPage.canvas.systemName, "pencil.and.scribble")
        XCTAssertNotNil(NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil))
        XCTAssertNotNil(NSImage(systemSymbolName: "pencil.and.scribble", accessibilityDescription: nil))
    }
}
