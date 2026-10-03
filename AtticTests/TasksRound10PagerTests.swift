import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Round 10, Astra's regression check of round 9 (three P2s): pages built
/// again keep their scroll position and take a `show` made before they
/// existed; every explicit way to a page cancels a swipe, even one whose
/// axis is not decided yet; a Tasks page that is not shown owns no scroll
/// event and runs no spring.
@MainActor
final class TasksRound10PagerTests: XCTestCase {
    private var store: TaskStore!
    private var model: TasksPageModel!
    private let width: CGFloat = 320
    private var time: TimeInterval = 1_000

    override func setUp() async throws {
        store = try makeTestStore()
        model = TasksPageModel(library: AtticLibrary(tasks: store), services: TasksPageServices())
        model.pagerSwipe.width = width
    }

    override func tearDown() {
        model = nil
        store = nil
    }

    private var swipe: TasksPagerSwipe { model.pagerSwipe }

    @discardableResult
    private func send(_ phase: TasksPagerSwipe.Sample.Phase, dx: CGFloat = 0, momentum: Bool = false) -> Bool {
        time += 1.0 / 120
        return model.pagerScrolled(.init(phase: phase, momentum: momentum, dx: dx, time: time), allowed: true)
    }

    // MARK: - Cancellation before the axis is decided (P2 2)

    /// A gesture that began with a still event, then a tab chosen, then
    /// sideways movement: the movement never pages from the new tab.
    func testATabChosenBeforeTheAxisIsDecidedEndsTheGesture() {
        send(.began)
        XCTAssertEqual(swipe.axis, .undecided)
        model.select(tab: .done)
        XCTAssertEqual(swipe.axis, .cancelled, "an undecided gesture is cancelled too")
        let before = swipe.motion.destination
        for _ in 0..<12 { XCTAssertTrue(send(.changed, dx: 40), "the rest of the gesture is ignored") }
        send(.ended)
        for _ in 0..<5 { XCTAssertTrue(send(.none, dx: 40, momentum: true), "and its momentum") }
        XCTAssertEqual(model.tab, .done, "Done stays chosen")
        XCTAssertEqual(swipe.motion.destination, before, "the page never followed")
        // The next gesture pages again.
        send(.began)
        for _ in 0..<10 { send(.changed, dx: 40) }
        send(.ended)
        XCTAssertEqual(model.tab, .backlog)
    }

    // MARK: - An inactive page owns nothing (P2 3)

    /// Tasks left for Notes mid-swipe: the rest of that gesture is not the
    /// pager's (it goes on to the page shown), and the page rests on its
    /// tab without travel.
    func testLeavingTasksMidSwipeLetsTheGestureGo() {
        send(.began)
        for _ in 0..<3 { send(.changed, dx: -30) }
        XCTAssertTrue(swipe.isTracking)
        model.isPageShown = false
        XCTAssertNil(swipe.axis, "the swipe is let go")
        XCTAssertFalse(swipe.motion.isSettling)
        for _ in 0..<10 { XCTAssertFalse(send(.changed, dx: -30), "Notes gets the rest of the gesture") }
        XCTAssertFalse(send(.ended))
        XCTAssertFalse(send(.none, dx: -30, momentum: true), "and its momentum")
        XCTAssertEqual(model.tab, .now)
        XCTAssertEqual(swipe.motion.position, 0, "Now, placed without travel")
        model.isPageShown = true
        send(.began)
        for _ in 0..<10 { send(.changed, dx: -30) }
        send(.ended)
        XCTAssertEqual(model.tab, .backlog, "back on Tasks, a swipe pages again")
    }

    /// Hiding the panel during a settle stops the spring: nothing steps
    /// while hidden, and the page is on its tab.
    func testHidingStopsTheSettle() {
        model.select(tab: .backlog)
        model.showPagerPage()
        XCTAssertTrue(swipe.motion.isSettling, "the slide is running")
        model.pageDidHide()
        XCTAssertFalse(swipe.motion.isSettling, "hiding stops it")
        XCTAssertEqual(swipe.motion.position, 1, "Later, without travel")
        XCTAssertFalse(send(.began), "hidden: no scroll event is the pager's")
        XCTAssertFalse(send(.changed, dx: -30))
        XCTAssertNil(swipe.axis)
        model.resetForReveal()
        XCTAssertEqual(model.tab, .now)
        XCTAssertEqual(swipe.motion.position, 0, "a reveal places the page at once")
        XCTAssertFalse(swipe.motion.isSettling)
    }

    // MARK: - Hosted

    /// ⌘F on Done during a swipe (the view's own route into the search):
    /// the swipe ends, and reversing the fingers keeps Done and its search.
    func testCommandFDuringASwipeEndsIt() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.go(to: .backlog)
        let model = hosted.model
        var time: TimeInterval = 0
        func send(_ phase: TasksPagerSwipe.Sample.Phase, dx: CGFloat = 0) {
            time += 1.0 / 120
            _ = model.pagerScrolled(.init(phase: phase, dx: dx, time: time), allowed: true)
        }
        send(.began)
        for _ in 0..<8 { send(.changed, dx: -30) }
        XCTAssertEqual(model.tab, .done, "the swipe reached Done live")
        hosted.press("f", keyCode: 3, modifiers: .command)
        XCTAssertEqual(model.pagerSwipe.axis, .cancelled, "⌘F ends the swipe")
        for _ in 0..<8 { send(.changed, dx: 30) }
        send(.ended)
        hosted.spin(0.8)
        XCTAssertEqual(model.tab, .done, "reversing the fingers changes nothing")
        XCTAssertTrue(hosted.searchHasKeyboard, "the search keeps the keyboard")
    }

    /// A `show` of a task far down Later while only Now is built: Later's
    /// list is built after the request and still brings the row into view.
    func testAShowIntoAnUnbuiltPageRevealsItsRow() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        // Later must not be built yet (round 11 keeps pages built once idle).
        hosted.model.pagerSwipe.motion.warms = false
        hosted.model.pagerSwipe.motion.coolDown()
        // A new task goes to the top of its group: the first made ends
        // up last, far down the list.
        var first: UUID?
        for index in 1...30 {
            let id = hosted.store.create(title: "Later errand \(index)", status: .backlog)?.id
            if first == nil { first = id }
        }
        let target = try XCTUnwrap(first)
        hosted.spin(0.5)
        XCTAssertEqual(hosted.shownPage(), 0)
        XCTAssertEqual(hosted.model.show(target), .shown)
        hosted.spin(1.5)
        XCTAssertEqual(hosted.shownPage(), 1)
        let list = try XCTUnwrap(onPageList(hosted))
        XCTAssertGreaterThan(list.contentView.bounds.origin.y, 200,
                             "Later's new list scrolled to the far row (at \(list.contentView.bounds.origin.y))")
        XCTAssertEqual(hosted.model.selection, [target])
    }

    /// A list scrolled down, left until its page is let go, and shown
    /// again: it is where it was.
    func testAListKeepsItsPlaceWhenItsPageIsBuiltAgain() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        // Its page must be let go and built again (round 11 keeps pages
        // built while the page is shown): none kept here.
        hosted.model.pagerSwipe.motion.warms = false
        hosted.model.pagerSwipe.motion.coolDown()
        for index in 1...30 { _ = hosted.store.create(title: "Later errand \(index)", status: .backlog) }
        hosted.go(to: .backlog)
        let list = try XCTUnwrap(onPageList(hosted))
        let clip = list.contentView
        clip.scroll(to: CGPoint(x: 0, y: 300))
        list.reflectScrolledClipView(clip)
        hosted.spin(0.3)
        hosted.go(to: .now)
        hosted.spin(0.6)
        XCTAssertEqual(hosted.model.pagerSwipe.span.pages, 0...0, "Later's page was let go")
        hosted.go(to: .backlog)
        let again = try XCTUnwrap(onPageList(hosted))
        XCTAssertFalse(again === list, "a new list")
        XCTAssertEqual(again.contentView.bounds.origin.y, 300, accuracy: 1, "back where it was")
    }

    /// CI run 3: Esc in the new-subtask field stops it wherever Esc would
    /// otherwise go, and ⌘Z undoes with no view in the page holding the
    /// keyboard (after a click on the selection bar).
    func testEscStopsASubtaskFieldAndCommandZUndoesFromAnywhere() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        let model = hosted.model
        let parent = try XCTUnwrap(model.rows(for: .now).first { $0.model.title == "Ship appearance PR" }?.id)
        model.beginAddingSubtask(to: parent)
        hosted.spin(0.6)
        XCTAssertEqual(model.newSubtaskParentID, parent)
        XCTAssertTrue((hosted.window.firstResponder as? NSTextView)?.isFieldEditor == true, "the field has the keyboard")
        hosted.press("\u{1B}", keyCode: 53)
        XCTAssertNil(model.newSubtaskParentID, "Esc stops the new subtask")

        let task = try XCTUnwrap(model.rows(for: .now).first { $0.model.title == "Call the plumber" }?.id)
        XCTAssertTrue(model.moveToBacklog([task]).isApplied)
        hosted.window.makeFirstResponder(nil)
        hosted.window.makeKey()
        hosted.spin(0.2)
        hosted.press("z", keyCode: 6, modifiers: .command)
        XCTAssertTrue(model.rows(for: .now).contains { $0.id == task }, "⌘Z brought it back with no view holding the keyboard")
    }

    /// The one list on the page (its frame starts at the page's left).
    private func onPageList(_ hosted: Hosted) -> NSScrollView? {
        guard let content = hosted.window.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        return hosted.lists(in: content).first { list in
            let frame = list.convert(list.bounds, to: nil)
            return frame.height > content.bounds.height / 2 && frame.minX > -1 && frame.minX < content.bounds.width / 2
        }
    }
}
