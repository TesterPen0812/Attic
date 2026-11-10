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
    #if !ATTIC_GENERATED_TESTS
    func testScreen9OpeningComposerCannotScrollAShortListUnderTheHeader() throws {
        let previousMotion = AtticMotionPreference.systemReduceMotionOverride
        AtticMotionPreference.systemReduceMotionOverride = true
        defer { AtticMotionPreference.systemReduceMotionOverride = previousMotion }
        let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: 320, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }

        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 300))
        scroll.hasVerticalScroller = true
        scroll.contentView.contentInsets = NSEdgeInsets(top: 60, left: 0, bottom: 20, right: 0)
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let keeper = TasksScrollKeeper.KeeperView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        document.addSubview(keeper)
        scroll.documentView = document
        window.contentView = scroll
        scroll.layoutSubtreeIfNeeded()
        XCTAssertTrue(keeper.enclosingScrollView === scroll, "the keeper must observe the real scroll view")

        // With just a heading and a few rows there is no scrollable content.
        // Extra *bottom* clearance from the card must not push the heading past the top inset.
        let top = TasksScrollKeeper.clampedOriginY(-.greatestFiniteMagnitude, in: scroll)
        XCTAssertEqual(TasksScrollKeeper.clampedOriginY(.greatestFiniteMagnitude, in: scroll), top, accuracy: 1)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: top))
        scroll.reflectScrolledClipView(scroll.contentView)
        let room = PanelComposerRoom()
        keeper.composerRoom = room
        room.set(height: 240, open: true)
        document.setFrameSize(CGSize(width: 300, height: 400))
        scroll.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertGreaterThan(TasksScrollKeeper.clampedOriginY(.greatestFiniteMagnitude, in: scroll), top + 50,
                             "the open card creates real scroll room below the list")
        XCTAssertEqual(scroll.contentView.bounds.minY, top, accuracy: 1,
                       "a short list's Today heading must stay below the header when the card opens")
    }
    #endif
    private func content(_ hosted: Hosted) -> NSView { hosted.window.contentView ?? NSView() }

    /// The pages' lists (the add bar's field has a scroll view too).
    private func pageLists(_ hosted: Hosted) -> [NSScrollView] {
        guard let content = hosted.window.contentView else { return [] }
        content.layoutSubtreeIfNeeded()
        return hosted.lists(in: content).filter { $0.frame.height > content.bounds.height / 2 }
    }

    func testBugs4HoveringCannotStarveTheNextTabsIdleWarmup() {
        let swipe = TasksPagerSwipe(count: 3)
        defer { swipe.motion.coolDown() }
        swipe.motion.inputAge = { type in
            type == .mouseMoved || type.rawValue == ~UInt32(0) ? 0 : 10
        }
        swipe.motion.warmUp(after: 0, isAllowed: { true })
        let end = Date().addingTimeInterval(1)
        while swipe.span.warm != 0...2, Date() < end { spinWarmRunLoop() }
        XCTAssertEqual(swipe.span.warm, 0...2, "moving toward a tab must not leave its construction on the click")
    }

    func testBugs4TypingStillPostponesWarmingUntilTheInputIsIdle() {
        let swipe = TasksPagerSwipe(count: 3)
        defer { swipe.motion.coolDown() }
        swipe.motion.inputAge = { type in
            type == .keyDown || type.rawValue == ~UInt32(0) ? 0 : 10
        }
        swipe.motion.warmUp(after: 0, isAllowed: { true })
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(swipe.span.warm)
        swipe.motion.inputAge = { type in
            type == .mouseMoved || type.rawValue == ~UInt32(0) ? 0 : 10
        }
        swipe.motion.warmUp(after: 0, isAllowed: { true })
        let end = Date().addingTimeInterval(1)
        while swipe.span.warm != 0...2, Date() < end { spinWarmRunLoop() }
        XCTAssertEqual(swipe.span.warm, 0...2)
    }

    private func spinWarmRunLoop() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
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

    func testBugs4SwitchingShellPagesRetainsTheWarmTaskTabsAcrossHide() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.spin(1.5)
        let before = Set(pageLists(hosted).map(ObjectIdentifier.init))
        XCTAssertEqual(hosted.model.pagerSwipe.span.warm, 0...2)
        hosted.model.isPageShown = false
        hosted.spin(0.1)
        XCTAssertEqual(hosted.model.pagerSwipe.span.warm, 0...2, "a shell switch must not put construction back on the next tab click")
        hosted.model.isPageShown = true
        hosted.model.pageDidReturn()
        hosted.go(to: .backlog)
        XCTAssertEqual(Set(pageLists(hosted).map(ObjectIdentifier.init)), before)
        hosted.model.pageDidHide()
        XCTAssertEqual(hosted.model.pagerSwipe.span.warm, 0...2, "the lightweight tab hosts remain ready across a hide (R-29)")
    }

    func testCoveredTaskPageHidesNativeListFromAccessibilityAndRestoresOnBack() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.spin(1.5)
        let list = try XCTUnwrap(pageLists(hosted).first { !$0.isHidden }, "Now list is visible before opening a task page")
        hosted.model.isPageShown = false
        hosted.spin(0.1)
        XCTAssertTrue(list.isHidden, "the covered page's native scroll view must leave AppKit accessibility")
        hosted.model.isPageShown = true
        hosted.spin(0.1)
        XCTAssertFalse(list.isHidden, "Back restores the same native scroll view")
    }

    func testLongListReturnsToExactSavedOffsetAfterRelaunch() throws {
        let suite = "AtticTests.TasksScrollRestore.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = TasksPageMemory(defaults: defaults)

        let first = try Hosted(height: 520, long: true, memory: memory)
        first.spin(1.5)
        let firstList = try XCTUnwrap(pageLists(first).first { !$0.isHidden })
        let bottom = TasksScrollKeeper.clampedOriginY(.greatestFiniteMagnitude, in: firstList)
        XCTAssertGreaterThan(bottom, 150, "the long list must have room to scroll")
        firstList.contentView.scroll(to: CGPoint(x: 0, y: bottom))
        firstList.reflectScrolledClipView(firstList.contentView)
        first.spin(0.2)
        let saved = try XCTUnwrap(first.model.scrollOffsets[.now])
        XCTAssertEqual(saved, bottom, accuracy: 2, "a scroll records the original position")
        first.close()

        let reopened = try Hosted(height: 520, long: true, memory: memory)
        defer { reopened.close() }
        reopened.spin(1.5)
        let list = try XCTUnwrap(pageLists(reopened).first { !$0.isHidden })
        let reopenedMax = TasksScrollKeeper.clampedOriginY(.greatestFiniteMagnitude, in: list)
        XCTAssertEqual(list.contentView.bounds.origin.y, saved, accuracy: 2,
                       "reopening must restore the original offset after the rows settle (final maximum \(reopenedMax), model \(String(describing: reopened.model.scrollOffsets[.now])), persisted \(String(describing: memory.scrollOffsets[.now])))")
    }

    /// Hiding the panel retains the built tab hosts under the lightweight
    /// retention budget; a reveal reuses them without a cold warm-up.
    func testHidingRetainsTheKeptPagesForTheNextReveal() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        hosted.spin(1.5)
        XCTAssertEqual(hosted.model.pagerSwipe.span.warm, 0...2)
        hosted.model.pageDidHide()
        XCTAssertEqual(hosted.model.pagerSwipe.span.warm, 0...2, "keep warmed hosts on hide")
        hosted.spin(1)
        XCTAssertEqual(hosted.model.pagerSwipe.span.warm, 0...2, "hidden tab hosts remain available")
        hosted.model.resetForReveal()
        hosted.spin(1.5)
        XCTAssertEqual(hosted.model.pagerSwipe.span.warm, 0...2, "already built when revealed")
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

    /// The supported recipes retain their timing and navigation-bounce limits.
    func testMotionIsCrisp() {
        let saved = AtticMotionTuning.current
        defer { AtticMotionTuning.current = saved }
        for feel in AtticMotionFeel.allCases {
            AtticMotionTuning.current = feel.tuning
            for preset in AtticMotionPreset.allCases {
                XCTAssertLessThanOrEqual(preset.duration, 0.35, "\(feel) \(preset) lingers")
            }
            for preset in [AtticMotionPreset.slide, .expand, .doneSlide, .pageSwitch] {
                XCTAssertLessThanOrEqual(preset.bounce, 0.2, "\(feel) \(preset) is navigation")
            }
        }
    }

    /// N-6 D, superseded by the owner's 10-17 decision: rows are no
    /// longer gone behind the tab labels; they run on under them, visible
    /// through the blur (`RoundO3ControlsTests`). Still: no overlay behind
    /// the tabs, and the first row rests clear of them.
    func testRowsRunOnUnderTheTabsAndRestClearOfThem() {
        let top = TasksViewport.topEdges(tabsTop: 80)
        XCTAssertEqual(top.top, TasksViewport.controlsBottom(tabsTop: 80), "the blur covers the tabs line")
        // The owner's panel design: no tabs line; `tabsTop` is the bottom
        // of the header (and the chips); the 2026-11-05 spacing increases the gap to 6.
        XCTAssertEqual(TasksViewport.listTop(tabsTop: 80), 86, "the first row rests below the header's controls")
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
