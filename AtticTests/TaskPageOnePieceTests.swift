import SwiftUI
import XCTest
@testable import Attic

/// A task's page opens in one piece (Accepted 2026-11-25): the drawing's
/// tracks on one spring, the opening's state from the click until Back has
/// landed, and the shared bars giving way on it.
@MainActor
final class TaskPageOnePieceTests: XCTestCase {
    private typealias One = TaskPageOnePiece

    // MARK: The drawing's tracks

    func testTracksLandWhereTheDrawingPutsThem() {
        let e = 1e-9
        // The list: gone by 0.55; the rows below half pushed there.
        XCTAssertEqual(One.lineOpacity(0), 1, accuracy: e)
        XCTAssertEqual(One.lineOpacity(0.55), 0, accuracy: e)
        XCTAssertEqual(One.linePush(0), 0, accuracy: e)
        XCTAssertEqual(One.linePush(0.55), 0.5, accuracy: e)
        XCTAssertEqual(One.linePush(1), 1, accuracy: e)
        // The row's title out and the head's in by 0.45 (the cross-fade).
        XCTAssertEqual(One.rowTitleOpacity(0.45), 0, accuracy: e)
        XCTAssertEqual(One.headOpacity(0), 0, accuracy: e)
        XCTAssertEqual(One.headOpacity(0.45), 1, accuracy: e)
        // The circles cross over the whole travel; the head's is in by 0.3.
        XCTAssertEqual(One.rowCircleOpacity(0.5), 0.5, accuracy: e)
        XCTAssertEqual(One.headCircleOpacity(0.3), 1, accuracy: e)
        // The row's rest: 40 % of the rise by 0.35, gone there.
        XCTAssertEqual(One.rowRestTravel(0.35), 0.4, accuracy: e)
        XCTAssertEqual(One.rowRestOpacity(0.35), 0, accuracy: e)
        XCTAssertEqual(One.highlightOpacity(0.4), 0, accuracy: e)
        XCTAssertEqual(One.topOpacity(0.4), 0, accuracy: e)
        // The page: details 0.2 → 0.75, the body by 0.6.
        XCTAssertEqual(One.detailsOpacity(0.2), 0, accuracy: e)
        XCTAssertEqual(One.detailsOpacity(0.75), 1, accuracy: e)
        XCTAssertEqual(One.bodyOpacity(0.6), 1, accuracy: e)
        // The bars: away by 0.45; Back and Aa held to 0.25, in by 0.85.
        XCTAssertEqual(One.barAway(0.45), 1, accuracy: e)
        XCTAssertEqual(One.backBarIn(0.25), 0, accuracy: e)
        XCTAssertEqual(One.backBarIn(0.85), 1, accuracy: e)
    }

    func testEveryTrackRunsOneWaySoBackRetracesTheOpening() {
        let rising: [(CGFloat) -> CGFloat] = [
            { One.linePush($0) }, { One.rowRestTravel($0) }, { CGFloat(One.headOpacity($0)) },
            { CGFloat(One.headCircleOpacity($0)) }, { CGFloat(One.detailsOpacity($0)) },
            { CGFloat(One.bodyOpacity($0)) }, { One.barAway($0) }, { One.backBarIn($0) },
        ]
        let falling: [(CGFloat) -> CGFloat] = [
            { CGFloat(One.lineOpacity($0)) }, { CGFloat(One.rowTitleOpacity($0)) },
            { CGFloat(One.rowCircleOpacity($0)) }, { CGFloat(One.rowRestOpacity($0)) },
            { CGFloat(One.highlightOpacity($0)) }, { CGFloat(One.topOpacity($0)) },
        ]
        let steps = (0...100).map { CGFloat($0) / 100 }
        for (index, track) in rising.enumerated() {
            XCTAssertEqual(zip(steps, steps.dropFirst()).first { track($1) < track($0) - 1e-9 }.map { $0.0 }, nil,
                           "rising track \(index) turns back")
        }
        for (index, track) in falling.enumerated() {
            XCTAssertEqual(zip(steps, steps.dropFirst()).first { track($1) > track($0) + 1e-9 }.map { $0.0 }, nil,
                           "falling track \(index) turns back")
        }
    }

    func testTravelCarriesTheSpringsOvershootAndOpacityStaysInBounds() {
        XCTAssertGreaterThan(One.linePush(1.05), 1, "the overshoot carries through travel, as in the drawing")
        XCTAssertGreaterThan(One.rowRestTravel(1.05), 1)
        for p: CGFloat in [-0.05, 1.05] {
            for value in [One.lineOpacity(p), One.headOpacity(p), One.rowTitleOpacity(p), One.bodyOpacity(p)] {
                XCTAssertTrue((0...1).contains(value), "opacity \(value) at \(p)")
            }
        }
    }

    // MARK: Where things are

    func testThePoseMeasuresTheRiseShiftsAndPushFromTheRow() {
        var pose = TaskPagePose(rowTitleX: 40, rowLineMid: 200, rowCircleX: 26, rowTop: 186, rowBottom: 214,
                                headTitleX: 46, headLineMid: 70, headCircleX: 30, height: 464,
                                scale: TaskPagePose.headScale)
        XCTAssertEqual(pose.rise, -130)
        XCTAssertEqual(pose.titleShift, 6)
        XCTAssertEqual(pose.circleShift, 4)
        XCTAssertEqual(pose.push, 250, "the rows below are pushed off the page")
        pose.rowBottom = 430
        XCTAssertEqual(pose.push, One.leastPush, "a row near the bottom still pushes the rest by the least push")
        XCTAssertEqual(TaskPagePose.headScale,
                       AtticTextStyle.noteTitle.nsFont.pointSize / AtticTextStyle.taskTitle.nsFont.pointSize,
                       accuracy: 1e-9)
        XCTAssertGreaterThan(TaskPagePose.headScale, 1, "the row's title grows into the head")
    }

    // MARK: One opening

    private func makeContent(title: String = "Plan the trip") throws -> (UUID, TaskPageStandInContent) {
        let container = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: container)
        let task = try XCTUnwrap(store.commit([TaskDraft(title: title)])?.first)
        let content = try XCTUnwrap(TaskPageStandInContent.make(task.id, store: store))
        return (task.id, content)
    }

    private let pose = TaskPagePose(rowTitleX: 40, rowLineMid: 200, rowCircleX: 26, rowTop: 186, rowBottom: 214,
                                    headTitleX: 46, headLineMid: 70, headCircleX: 30, height: 464, scale: 1.5)

    func testTheStandInIsDrawnFromTheTasksOwnData() throws {
        let (_, content) = try makeContent()
        XCTAssertEqual(content.title, "Plan the trip")
        XCTAssertNil(content.writing, "no note: nothing under the subtasks")
        XCTAssertTrue(content.rows.isEmpty)
    }

    func testAnOpeningRunsFromTheClickUntilItEndsAndTheListReadsItsProgress() throws {
        let (id, content) = try makeContent()
        let motion = TaskPageMotion()
        XCTAssertFalse(motion.isActive)
        XCTAssertNil(motion.way, "no opening: the list reads nothing")
        motion.begin(id, content: content, pose: pose)
        XCTAssertTrue(motion.isActive)
        XCTAssertEqual(motion.progress, 0, "every part starts where it is at the click")
        XCTAssertFalse(motion.handedOver)
        XCTAssertEqual(motion.way, TaskPageMakeWay(anchorID: id, pose: pose, progress: 0))
        motion.progress = 0.4
        XCTAssertEqual(motion.way?.progress, 0.4)
        motion.end()
        XCTAssertFalse(motion.isActive)
        XCTAssertNil(motion.way)
        XCTAssertEqual(motion.progress, 0)
    }

    /// The list's readers observe the progress alone, so the click's own
    /// writes must not reach them: told of those first, they took the
    /// spring's change with them, unanimated (CI run 45890021290).
    func testTheClickWritesNothingTheListObserves() throws {
        let (id, content) = try makeContent()
        let motion = TaskPageMotion()
        final class Count: @unchecked Sendable { var n = 0 }
        let told = Count()
        func observe() {
            withObservationTracking { _ = motion.progress; _ = motion.listTab } onChange: { told.n += 1 }
        }
        observe()
        motion.begin(id, content: content, pose: pose)
        XCTAssertEqual(told.n, 0, "the click tells the list nothing")
        XCTAssertEqual(motion.place?.anchorID, id, "and its row and head are there to read")
        XCTAssertEqual(motion.place?.pose, pose)
        var moved = pose
        moved.rowTop += 40
        moved.rowBottom += 40
        motion.retarget(content: nil, pose: moved)
        XCTAssertEqual(told.n, 0, "nor does Back finding the row again")
        XCTAssertEqual(motion.place?.pose, moved)
        motion.progress = 1
        XCTAssertEqual(told.n, 1, "the spring's change is the first it hears")
        observe()
        motion.progress = 0
        told.n = 0
        observe()
        motion.end()
        XCTAssertEqual(told.n, 0, "an opening that ended at the row writes nothing either")
        XCTAssertNil(motion.place)
    }

    func testBackAndAaFoldAsTheMotionPassesTheirPart() {
        // Towards the page: held to 0.25, as the drawing holds them.
        XCTAssertFalse(One.backBarShown(0, opening: true))
        XCTAssertFalse(One.backBarShown(0.25, opening: true))
        XCTAssertTrue(One.backBarShown(0.26, opening: true))
        // Back: there in the first frame, away once the motion leaves 0.85.
        XCTAssertTrue(One.backBarShown(1, opening: false), "Back's first frame still has the buttons")
        XCTAssertTrue(One.backBarShown(0.86, opening: false))
        XCTAssertFalse(One.backBarShown(0.85, opening: false))
        XCTAssertFalse(One.backBarShown(0, opening: false))
    }

    func testThePageIsBuiltOnlyOnceTheSpringTowardsItHasSettled() async throws {
        let (id, content) = try makeContent()
        let motion = TaskPageMotion()
        motion.begin(id, content: content, pose: pose)
        motion.open = true
        motion.landingPending = true
        motion.progress = 1
        let waiting = Task { await motion.waitForLanding() }
        await Task.yield()
        motion.landed(true)
        let built = await waiting.value
        XCTAssertTrue(built, "the spring settled at the page: build it")
        let settled = await motion.waitForLanding()
        XCTAssertTrue(settled, "already at the page: no wait")
    }

    func testAnOpeningThatTurnsBackOrEndsBuildsNothing() async throws {
        let (id, content) = try makeContent()
        let motion = TaskPageMotion()
        motion.begin(id, content: content, pose: pose)
        motion.open = true
        motion.landingPending = true
        let turned = Task { await motion.waitForLanding() }
        await Task.yield()
        motion.open = false
        motion.landed(false)
        let builtAfterTurn = await turned.value
        XCTAssertFalse(builtAfterTurn, "Back before the page was built: no page")

        motion.open = true
        motion.landingPending = true
        let ended = Task { await motion.waitForLanding() }
        await Task.yield()
        motion.end()
        let builtAfterEnd = await ended.value
        XCTAssertFalse(builtAfterEnd, "an ended opening releases its waiter")
    }

    func testBackFindsTheRowAgainButKeepsTheLastPlaceWhenTheRowIsGone() throws {
        let (id, content) = try makeContent()
        let motion = TaskPageMotion()
        motion.begin(id, content: content, pose: pose)
        var moved = pose
        moved.rowLineMid = 260
        motion.retarget(content: nil, pose: moved)
        XCTAssertEqual(motion.pose, moved, "the list scrolled: Back goes to the row where it is now")
        motion.retarget(content: nil, pose: nil)
        XCTAssertEqual(motion.pose, moved, "no row: the stand-in keeps its places and fades")
        XCTAssertEqual(motion.content, content)
    }

    // MARK: The shared bars

    func testTheBarsGiveWayOnTheMotionAndAreWholeAgainAfterBack() {
        let chrome = PanelSharedChrome()
        chrome.setGivingWay(1, page: .tasks)
        XCTAssertNil(chrome.givingWay[.tasks], "no opening: the bars don't move")

        chrome.setCovered(true, page: .tasks, onePiece: true)
        XCTAssertTrue(chrome.covered.contains(.tasks))
        XCTAssertNotNil(chrome.coverAnimation(.tasks, folding: true, reduceMotion: false))
        XCTAssertNil(chrome.coverAnimation(.tasks, folding: true, reduceMotion: true), "Reduce Motion: at once")
        XCTAssertNil(chrome.coverAnimation(.notes, folding: true, reduceMotion: false), "other pages: at once")
        chrome.setGivingWay(1, page: .tasks)
        XCTAssertEqual(chrome.givingWay[.tasks], 1)

        // Back: the bars come back on the way down, then the opening ends.
        chrome.setCovered(false, page: .tasks, onePiece: true)
        chrome.setGivingWay(0, page: .tasks)
        XCTAssertFalse(chrome.covered.contains(.tasks))
        XCTAssertEqual(chrome.givingWay[.tasks], 0)
        chrome.endOnePiece(page: .tasks)
        XCTAssertNil(chrome.givingWay[.tasks], "no drop left on the bars after Back")
        XCTAssertFalse(chrome.onePieceCover.contains(.tasks))
        XCTAssertNil(chrome.coverAnimation(.tasks, folding: false, reduceMotion: false), "later coverings: at once")
    }

    func testAnOrdinaryCoveringClearsAnOpeningsDrop() {
        let chrome = PanelSharedChrome()
        chrome.setCovered(true, page: .tasks, onePiece: true)
        chrome.setGivingWay(0.5, page: .tasks)
        chrome.setCovered(true, page: .tasks)
        XCTAssertFalse(chrome.onePieceCover.contains(.tasks))
        XCTAssertNil(chrome.givingWay[.tasks])
        XCTAssertTrue(chrome.covered.contains(.tasks))
    }
}
