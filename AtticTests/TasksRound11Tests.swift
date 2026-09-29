import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Round 11 (performance): the pages beside the one shown are kept built
/// once the page is idle, hidden in AppKit (their lists draw nothing, take
/// no click and are not read); a tab click then builds nothing. The
/// pager's settle steps on a clock and ends; motion presets stay crisp.
@MainActor
final class TasksRound11Tests: XCTestCase {
    private func content(_ hosted: Hosted) -> NSView { hosted.window.contentView ?? NSView() }

    /// The pages' lists (the add bar's field has a scroll view too).
    private func pageLists(_ hosted: Hosted) -> [NSScrollView] {
        guard let content = hosted.window.contentView else { return [] }
        content.layoutSubtreeIfNeeded()
        return hosted.lists(in: content).filter { $0.frame.height > content.bounds.height / 2 }
    }

    /// Once idle, all three pages are built; the ones not shown hide their
    /// lists (nothing drawn, nothing read), and the page shown reads its rows.
    func testThePagesBesideTheOneShownAreBuiltHiddenOnceIdle() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.spin(1.5)
        let span = hosted.model.pagerSwipe.span
        XCTAssertEqual(span.warm, 0...2, "every page kept built")
        XCTAssertEqual(span.pages, 0...0, "only Now drawn")
        let lists = pageLists(hosted)
        XCTAssertEqual(lists.count, 3, "three lists built")
        XCTAssertEqual(lists.filter { !$0.isHidden }.count, 1, "only the page shown draws its list")
        // A hidden view is not drawn, not hit and not read by VoiceOver
        // (the UI tests read the pages through the accessibility tree).
        let width = content(hosted).bounds.width
        XCTAssertTrue(lists.filter(\.isHidden).allSatisfy { list in
            let frame = list.convert(list.bounds, to: nil)
            return frame.minX >= width - 1 || frame.maxX <= 1
        }, "the hidden lists lie beside the page")
    }

    /// A tab click with the pages kept built builds nothing: Later's list
    /// is the one built while idle, now shown and read, and Now's hides.
    func testATabClickShowsTheKeptPageWithoutBuildingIt() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.spin(1.5)
        let before = Set(pageLists(hosted).map(ObjectIdentifier.init))
        hosted.go(to: .backlog)
        let after = pageLists(hosted)
        XCTAssertEqual(Set(after.map(ObjectIdentifier.init)), before, "no list built or let go")
        XCTAssertEqual(hosted.shownPage(), 1)
        XCTAssertEqual(after.filter { !$0.isHidden }.count, 1, "only Later draws")
        hosted.go(to: .now)
        XCTAssertEqual(hosted.shownPage(), 0, "and back again")
        XCTAssertEqual(pageLists(hosted).filter { !$0.isHidden }.count, 1, "only Now draws")
    }

    /// Hiding the panel lets the kept pages go; the next reveal builds them
    /// again once idle.
    func testHidingLetsTheKeptPagesGo() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.spin(1.5)
        XCTAssertEqual(hosted.model.pagerSwipe.span.warm, 0...2)
        hosted.model.pageDidHide()
        XCTAssertNil(hosted.model.pagerSwipe.span.warm, "let go on hide")
        hosted.spin(1)
        XCTAssertNil(hosted.model.pagerSwipe.span.warm, "not built while hidden")
        hosted.model.resetForReveal()
        hosted.spin(1.5)
        XCTAssertEqual(hosted.model.pagerSwipe.span.warm, 0...2, "built again once revealed and idle")
    }

    /// A swipe's neighbour is the page kept built: the swipe builds nothing.
    func testASwipeMovesTheKeptPage() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.spin(1.5)
        let before = Set(pageLists(hosted).map(ObjectIdentifier.init))
        let model = hosted.model
        var time: TimeInterval = 0
        func send(_ phase: TasksPagerSwipe.Sample.Phase, dx: CGFloat = 0) {
            time += 1.0 / 120
            _ = model.pagerScrolled(.init(phase: phase, dx: dx, time: time), allowed: true)
        }
        send(.began)
        for _ in 0..<40 { send(.changed, dx: -30) }
        XCTAssertEqual(pageLists(hosted).filter { !$0.isHidden }.count, 2, "Now and Later drawn while the fingers move")
        send(.ended)
        hosted.spin(1.2)
        XCTAssertEqual(hosted.shownPage(), 1)
        XCTAssertEqual(Set(pageLists(hosted).map(ObjectIdentifier.init)), before, "no list built or let go")
    }

    /// The settle's clock: it runs only while the page moves.
    func testTheSettleClockStopsWhenThePageRests() throws {
        let clock = TasksDisplayClock()
        var ticks = 0
        clock.start(on: nil) { _, _, _ in
            ticks += 1
            return ticks < 5
        }
        XCTAssertTrue(clock.isRunning)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(ticks, 5)
        XCTAssertFalse(clock.isRunning, "stopped when the motion said it was done")
    }

    /// Navigation never bounces; small things that appear bounce lightly;
    /// everything lands in about a quarter of a second (spec § Motion).
    func testMotionIsCrisp() {
        for preset in AtticMotionPreset.allCases {
            XCTAssertLessThanOrEqual(preset.duration, 0.28, "\(preset) lingers")
        }
        for preset in [AtticMotionPreset.slide, .expand, .doneSlide, .pageSwitch] {
            XCTAssertEqual(preset.bounce, 0, "\(preset) is navigation")
        }
        XCTAssertLessThanOrEqual(AtticMotionPreset.popover.bounce, 0.15)
    }

    /// The fade under the tabs: nothing scrolled under them shows.
    func testNothingShowsUnderTheTabs() {
        let stops = TasksViewport.maskStops(height: 520, tabsTop: 80, listTop: 110, bottomStack: 60)
        let underLabels = stops.filter { $0.location <= 96.0 / 520 + 0.0001 }
        XCTAssertTrue(underLabels.allSatisfy { $0.opacity == 0 }, "rows under the tab labels are gone")
        XCTAssertEqual(stops.first { $0.location >= 110.0 / 520 - 0.0001 }?.opacity, 1, "fully there from the first row's rest")
    }

    /// Files over the page land on the row under them, never on another.
    func testAFileDropFindsTheRowUnderIt() {
        let a = UUID(), b = UUID(), c = UUID()
        let frames = [TasksRowID(tab: .now, id: a): CGRect(x: 0, y: 100, width: 300, height: 34),
                      TasksRowID(tab: .now, id: b): CGRect(x: 0, y: 134, width: 300, height: 34),
                      TasksRowID(tab: .now, id: c): CGRect(x: 360, y: 100, width: 300, height: 34)]
        XCTAssertEqual(TasksPage.row(at: CGPoint(x: 50, y: 140), frames: frames, tab: .now, among: [a, b]), b)
        XCTAssertNil(TasksPage.row(at: CGPoint(x: 400, y: 110), frames: frames, tab: .now, among: [a, b]), "a row of another page")
        XCTAssertNil(TasksPage.row(at: CGPoint(x: 50, y: 300), frames: frames, tab: .now, among: [a, b]))
    }
}
