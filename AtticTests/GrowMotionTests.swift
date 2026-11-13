import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Motion into notes (Accepted 2026-11-13): a task's page grows from its
/// row and a note from its gallery card, and both shrink back on the way
/// out, starting on the click. Both Reduced choices and interruptions.
@MainActor
final class GrowMotionTests: XCTestCase {
    private let row = AtticGrowOrigin(frame: CGRect(x: 16, y: 300, width: 288, height: 28),
                                      cornerRadius: AtticRadius.highlight, title: "Buy milk")
    private let card = AtticGrowOrigin(frame: CGRect(x: 16, y: 200, width: 140, height: 120),
                                       cornerRadius: NotesBoardMetrics.radius, title: "Ideas")

    // MARK: Task → its page

    func testTaskPageGrowsFromItsRowAtTheClickAndShrinksBack() {
        var state = AtticGrowState()
        state.open(from: row, reduceMotion: false, reducedStyle: .instant)
        XCTAssertEqual(state.style, .grow)
        XCTAssertEqual(state.phase, .opening)
        XCTAssertTrue(state.drawsShell, "the shell moves from the click, before the page is built")
        XCTAssertEqual(state.shellTarget, 1)
        XCTAssertTrue(state.showsDestination)
        XCTAssertFalse(state.showsOrigin, "the list leaves at the click")
        XCTAssertNotNil(state.shellAnimation)

        state.finish(state.generation)
        XCTAssertEqual(state.phase, .open)
        XCTAssertFalse(state.drawsShell, "nothing over the page once it is there")

        state.close(to: row, reduceMotion: false, reducedStyle: .instant)
        XCTAssertEqual(state.phase, .closing)
        XCTAssertEqual(state.shellTarget, 0)
        XCTAssertTrue(state.showsOrigin, "the list comes back with Back's click")
        XCTAssertFalse(state.showsDestination, "the page fades at once, before its save finishes")
        state.finish(state.generation)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.origin)
    }

    func testRouteLooksKeepTodaysRouteUnderInstantAndHideTheListFromTheClickOtherwise() {
        var state = AtticGrowState()
        state.open(from: row, reduceMotion: true, reducedStyle: .instant)
        // Instant: the list stays until the page is there, then the page.
        XCTAssertEqual(TaskNoteRouteHost<EmptyView>.looks(state, shown: false),
                       .init(originCurrent: true, originShows: true, destinationShows: true))
        XCTAssertEqual(TaskNoteRouteHost<EmptyView>.looks(state, shown: true),
                       .init(originCurrent: false, originShows: false, destinationShows: true))

        state = AtticGrowState()
        state.open(from: row, reduceMotion: false, reducedStyle: .instant)
        let building = TaskNoteRouteHost<EmptyView>.looks(state, shown: false)
        XCTAssertFalse(building.originShows, "the list fades at the click, while the page builds")
        XCTAssertFalse(building.originCurrent, "a second click can't land on the fading list")
        state.close(to: row, reduceMotion: false, reducedStyle: .instant)
        let leaving = TaskNoteRouteHost<EmptyView>.looks(state, shown: true)
        XCTAssertTrue(leaving.originShows)
        XCTAssertFalse(leaving.destinationShows)
        XCTAssertFalse(leaving.originCurrent, "the list takes clicks only once the page has let go")
    }

    // MARK: Gallery → a note

    func testNoteGrowsFromItsCardAndAClickOnAnotherCardMidShrinkStartsThere() {
        var state = AtticGrowState()
        state.open(from: card, reduceMotion: false, reducedStyle: .instant)
        XCTAssertEqual(state.origin, card)
        state.finish(state.generation)
        state.close(to: nil, reduceMotion: false, reducedStyle: .instant)
        XCTAssertEqual(state.origin, card, "a card not laid out yet: back to where it grew from")
        XCTAssertEqual(state.phase, .closing)

        let other = AtticGrowOrigin(frame: CGRect(x: 164, y: 200, width: 140, height: 90), cornerRadius: 24, title: "Trip")
        state.reset()
        state.open(from: other, reduceMotion: false, reducedStyle: .instant)
        XCTAssertEqual(state.origin, other)
        XCTAssertEqual(state.phase, .opening)
    }

    // MARK: Reduce Motion, both choices

    func testReducedInstantIsTodaysChangeAndReducedFadeIsTheFastFade() {
        var instant = AtticGrowState()
        instant.open(from: row, reduceMotion: true, reducedStyle: .instant)
        XCTAssertEqual(instant.style, .instant)
        XCTAssertEqual(instant.phase, .open, "Instant: no moving phase at all")
        XCTAssertFalse(instant.drawsShell)
        XCTAssertNil(instant.destinationAnimation(showing: true))
        instant.close(to: row, reduceMotion: true, reducedStyle: .instant)
        XCTAssertEqual(instant.phase, .idle)

        var fade = AtticGrowState()
        fade.open(from: row, reduceMotion: true, reducedStyle: .fade)
        XCTAssertEqual(fade.style, .fade)
        XCTAssertFalse(fade.drawsShell, "Reduced never scales or moves")
        XCTAssertNil(fade.shellAnimation)
        XCTAssertNotNil(fade.destinationAnimation(showing: true))
        XCTAssertNotNil(fade.originAnimation(showing: false))
    }

    func testNoOriginFadesInsteadOfGrowing() {
        var state = AtticGrowState()
        state.open(from: nil, reduceMotion: false, reducedStyle: .instant)
        XCTAssertEqual(state.style, .fade, "⌘Return with no row on show: a fade, never a shell from nowhere")
        XCTAssertFalse(state.drawsShell)
    }

    // MARK: Interruptions

    func testBackMidGrowReversesAndAStaleCompletionDoesNotSettleIt() {
        var state = AtticGrowState()
        state.open(from: row, reduceMotion: false, reducedStyle: .instant)
        let opening = state.generation
        state.close(to: row, reduceMotion: false, reducedStyle: .instant)
        XCTAssertEqual(state.phase, .closing, "Escape mid-motion turns it round")
        state.finish(opening)
        XCTAssertEqual(state.phase, .closing, "the first run's completion belongs to a run that no longer exists")
        state.finish(state.generation)
        XCTAssertEqual(state.phase, .idle)
    }

    func testARefusedBackGrowsTheShellBackOverThePage() {
        var state = AtticGrowState()
        state.open(from: row, reduceMotion: false, reducedStyle: .instant)
        state.finish(state.generation)
        state.close(to: row, reduceMotion: false, reducedStyle: .instant)
        state.refuseClose()
        XCTAssertEqual(state.phase, .opening)
        XCTAssertTrue(state.showsDestination, "the page (and its undo history) is still there")
        XCTAssertEqual(state.shellTarget, 1)
        state.refuseClose()
        XCTAssertEqual(state.phase, .opening, "only a shrink can be refused")
    }

    func testClickingAgainMidShrinkReopens() {
        var state = AtticGrowState()
        state.open(from: row, reduceMotion: false, reducedStyle: .instant)
        state.finish(state.generation)
        state.close(to: row, reduceMotion: false, reducedStyle: .instant)
        state.open(from: nil, reduceMotion: false, reducedStyle: .instant)
        XCTAssertEqual(state.phase, .opening)
        XCTAssertEqual(state.origin, row, "turns round towards the page from the same row")
        XCTAssertEqual(state.style, .grow)
    }

    // MARK: Geometry

    func testShellPlanGrowsFromTheRowAndTurnsRoundFromWhereItIs() {
        let rowRect = CGRect(x: 8, y: 100, width: 300, height: 28)
        let page = CGRect(x: 0, y: 0, width: 320, height: 520)
        var state = AtticGrowState()
        state.open(from: row, reduceMotion: false, reducedStyle: .instant)
        let open = try! XCTUnwrap(AtticGrowPlan.make(state, origin: rowRect, page: page, current: nil))
        XCTAssertEqual(open.from.frame, rowRect)
        XCTAssertEqual(open.from.opacity, 1)
        XCTAssertEqual(open.to.frame, page)
        XCTAssertEqual(open.to.opacity, AtticGrowPlan.holdOpacity, "it holds over the page being built")
        XCTAssertEqual(open.titleStart, 0)
        XCTAssertEqual(open.titleEnd, Double(AtticGrowState.titleFadeEnd), accuracy: 0.0001)

        // Escape halfway: the shrink starts from the shell as it is.
        let midway = AtticGrowPlan.Pose(frame: CGRect(x: 4, y: 50, width: 310, height: 270), radius: 18,
                                        opacity: 0.5, titleOpacity: 0)
        state.close(to: row, reduceMotion: false, reducedStyle: .instant)
        let back = try! XCTUnwrap(AtticGrowPlan.make(state, origin: rowRect, page: page, current: midway))
        XCTAssertEqual(back.from, midway)
        XCTAssertEqual(back.to.frame, rowRect)
        XCTAssertEqual(back.to.opacity, 1, "it lands as the selected row's highlight")
        XCTAssertGreaterThan(back.titleStart, 0.5, "the title comes back only near the row")

        state.finish(state.generation)
        XCTAssertNil(AtticGrowPlan.make(state, origin: rowRect, page: page, current: nil), "nothing drawn at rest")
        var reduced = AtticGrowState()
        reduced.open(from: row, reduceMotion: true, reducedStyle: .fade)
        XCTAssertNil(AtticGrowPlan.make(reduced, origin: rowRect, page: page, current: nil), "Reduced never draws the shell")
    }

    func testTheShellHoldsUntilThePageArrivesAndARefusedBackNeedsNoBuild() {
        var state = AtticGrowState()
        state.open(from: row, reduceMotion: false, reducedStyle: .instant)
        XCTAssertFalse(state.arrived, "the page is still being built")
        state.destinationArrived()
        XCTAssertTrue(state.arrived)
        state.finish(state.generation)
        state.destinationArrived()
        XCTAssertEqual(state.phase, .open)
        state.close(to: row, reduceMotion: false, reducedStyle: .instant)
        state.refuseClose()
        XCTAssertTrue(state.arrived, "the page never left: the shell gives way at once")
        state.reset()
        state.open(from: row, reduceMotion: false, reducedStyle: .instant)
        XCTAssertFalse(state.arrived, "each opening waits for its own page")
    }

    func testOriginClearsAtOnceUnderTheShellButFadesWithoutOne() {
        var grow = AtticGrowState()
        grow.open(from: row, reduceMotion: false, reducedStyle: .instant)
        XCTAssertNil(grow.originAnimation(showing: false), "no half-faded list while the page builds")
        XCTAssertNotNil(grow.originAnimation(showing: true))
        var fade = AtticGrowState()
        fade.open(from: nil, reduceMotion: false, reducedStyle: .instant)
        XCTAssertNotNil(fade.originAnimation(showing: false))
    }

    func testTaskRowOriginIsTheRowsHighlight() {
        let slot = CGRect(x: 0, y: 100, width: 320, height: AtticLayout.rowPitch)
        let origin = AtticGrowOrigin.taskRow(slot, title: "A", windowNumber: 7)
        XCTAssertEqual(origin.frame.height, AtticLayout.rowHighlightHeight)
        XCTAssertEqual(origin.frame.minX, AtticLayout.rowHighlightInset)
        XCTAssertEqual(origin.frame.midY, slot.midY)
        XCTAssertEqual(origin.windowNumber, 7)
        XCTAssertNotNil(AtticGrowOrigin.band(at: CGPoint(x: 50, y: 200), contentWidth: 320))
        XCTAssertNil(AtticGrowOrigin.band(at: .zero, contentWidth: 10))
    }
}
