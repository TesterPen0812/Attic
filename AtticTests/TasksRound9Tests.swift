import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

/// Round 9: the pager owns its gesture (owner items 24 and 25) and motion
/// has a Settings choice (item 26). The decisions are pure and fed with the
/// scroll events a trackpad and a wheel send; `pagerScrolled` applies them
/// to the model as the page's monitor does.
@MainActor
final class TasksRound9Tests: XCTestCase {
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
    private var position: CGFloat { swipe.motion.position }

    /// One trackpad sample, 1/120 s after the last. `dx` is AppKit's
    /// `scrollingDeltaX`: negative moves toward the next page.
    @discardableResult
    private func send(_ phase: TasksPagerSwipe.Sample.Phase, dx: CGFloat = 0, dy: CGFloat = 0, momentum: Bool = false,
                      precise: Bool = true, gap: TimeInterval = 1.0 / 120, allowed: Bool = true) -> Bool {
        time += gap
        return model.pagerScrolled(.init(phase: phase, momentum: momentum, dx: dx, dy: dy, time: time, precise: precise),
                                   allowed: allowed)
    }

    /// A whole trackpad swipe: began, `steps` movements of `dx`, then the
    /// fingers lift (`pause` after the last movement), then its momentum.
    private func swipe(steps: Int, dx: CGFloat, pause: TimeInterval = 1.0 / 120, momentum: Int = 20) {
        send(.began)
        for _ in 0..<steps { send(.changed, dx: dx) }
        send(.ended, gap: pause)
        for _ in 0..<momentum { send(.none, dx: dx, momentum: true) }
    }

    // MARK: - Decisions

    /// Released: past a quarter of a page it turns, short of it it stays,
    /// a flick turns it however short, and a flick back returns it.
    func testReleaseDecidesByDistanceOrVelocity() {
        func target(_ travel: CGFloat, _ velocity: CGFloat, from origin: Int = 1) -> Int {
            TasksPagerSwipe.target(origin: origin, travel: travel, velocity: velocity, width: width, count: 3)
        }
        XCTAssertEqual(target(width * 0.2, 0), 1, "a fifth of a page, slowly: back")
        XCTAssertEqual(target(width * 0.3, 0), 2, "past a quarter: the next page")
        XCTAssertEqual(target(-width * 0.3, 0), 0, "past a quarter the other way: the previous page")
        XCTAssertEqual(target(width * 0.05, 900), 2, "a short flick turns the page")
        XCTAssertEqual(target(-width * 0.05, -900), 0)
        XCTAssertEqual(target(width * 0.7, -900), 1, "a flick back returns it")
        XCTAssertEqual(target(width * 0.2, 200), 1, "slower than a flick and short: back")
        XCTAssertEqual(target(width * 5, 20_000), 2, "never more than one page")
        XCTAssertEqual(target(width * 0.9, 0, from: 2), 2, "never past the last page")
        XCTAssertEqual(target(-width * 0.9, -2_000, from: 0), 0, "nor before the first")
        XCTAssertEqual(TasksPagerSwipe.target(origin: 1, travel: 500, velocity: 0, width: 0, count: 3), 1, "no width yet: stay")
    }

    /// The fingers move the page 1:1 up to the neighbour, then a firm
    /// rubber band: however far they go, the page gives at most a tenth
    /// of a page more, so Done is never reached from Now.
    func testThePageFollowsToTheNeighbourThenResists() {
        XCTAssertEqual(TasksPagerSwipe.position(origin: 0, travel: 0.4, count: 3), 0.4, accuracy: 0.0001)
        XCTAssertEqual(TasksPagerSwipe.position(origin: 0, travel: 1, count: 3), 1, accuracy: 0.0001)
        let beyond = TasksPagerSwipe.position(origin: 0, travel: 1.3, count: 3)
        XCTAssertGreaterThan(beyond, 1, "it gives a little past the neighbour")
        XCTAssertLessThan(TasksPagerSwipe.position(origin: 0, travel: 50, count: 3), 1.1, "never a tenth more")
        XCTAssertLessThan(TasksPagerSwipe.position(origin: 0, travel: -50, count: 3), 0)
        XCTAssertGreaterThan(TasksPagerSwipe.position(origin: 0, travel: -50, count: 3), -0.1, "before Now: a tenth at most")
        XCTAssertGreaterThan(TasksPagerSwipe.position(origin: 2, travel: -50, count: 3), 0.9, "from Done: Later, not Now")
    }

    /// The tab follows the page: it changes as the page crosses halfway,
    /// back again if the fingers return, and never past the neighbour.
    func testTheLiveTabChangesAtHalfway() {
        XCTAssertEqual(TasksPagerSwipe.livePage(origin: 0, travel: 0.49, count: 3), 0)
        XCTAssertEqual(TasksPagerSwipe.livePage(origin: 0, travel: 0.5, count: 3), 1)
        XCTAssertEqual(TasksPagerSwipe.livePage(origin: 0, travel: 3, count: 3), 1, "never two pages")
        XCTAssertEqual(TasksPagerSwipe.livePage(origin: 1, travel: -0.6, count: 3), 0)
        XCTAssertEqual(TasksPagerSwipe.livePage(origin: 0, travel: -0.8, count: 3), 0, "nothing before Now")
    }

    /// A released page's speed never carries it past the page: the
    /// critically damped spring's start is capped below 2π / duration.
    func testTheReleaseNeverOvershoots() {
        let duration = AtticMotionPreset.slide.duration
        let limit = 2 * Double.pi / duration
        XCTAssertLessThan(AtticMotionPreset.releaseVelocity(velocity: 50_000, distance: 40, duration: duration), limit)
        XCTAssertEqual(AtticMotionPreset.releaseVelocity(velocity: 600, distance: 200, duration: duration), 3, accuracy: 0.0001)
        XCTAssertEqual(AtticMotionPreset.releaseVelocity(velocity: -600, distance: 200, duration: duration), 0, "moving away: from rest")
        XCTAssertEqual(AtticMotionPreset.releaseVelocity(velocity: 600, distance: 0, duration: duration), 0, "already there")
        XCTAssertNotNil(AtticMotionPreset.release(velocity: 600, distance: 200, reduceMotion: false))
    }

    // MARK: - The gesture, as a trackpad sends it

    /// A hard swipe from Now: the page follows, the tab turns to Later as
    /// the page crosses halfway (long before the fingers lift), the page
    /// never goes a tenth past Later, its momentum is ignored, and it
    /// rests on Later.
    func testAHardSwipeFromNowLandsOnLaterWithTheTabLive() {
        XCTAssertFalse(send(.began), "the gesture's start goes on (the list sees a whole gesture)")
        var furthest: CGFloat = 0
        var tabTurnedAt: Int?
        for step in 0..<60 {
            XCTAssertTrue(send(.changed, dx: -40), "a horizontal swipe is the pager's")
            furthest = max(furthest, position)
            if tabTurnedAt == nil, model.tab == .backlog { tabTurnedAt = step }
        }
        XCTAssertEqual(tabTurnedAt, 3, "Later is selected as the page crosses halfway (160 of 320 pt)")
        XCTAssertLessThan(furthest, 1.1, "2,400 pt of travel never reaches Done")
        XCTAssertFalse(send(.ended), "the gesture's end goes on too")
        XCTAssertEqual(model.tab, .backlog)
        XCTAssertEqual(position, 1, "it rests on Later")
        for _ in 0..<30 {
            XCTAssertTrue(send(.none, dx: -60, momentum: true), "its momentum is ignored")
        }
        XCTAssertEqual(model.tab, .backlog)
        XCTAssertEqual(position, 1)
    }

    /// The same swipe from Done goes to Later, never Now.
    func testAHardSwipeFromDoneLandsOnLater() {
        model.select(tab: .done)
        swipe(steps: 60, dx: 40)
        XCTAssertEqual(model.tab, .backlog)
        XCTAssertEqual(position, 1)
    }

    /// A slow drag a fifth of a page returns; a quick short flick turns.
    func testShortDragsReturnAndFlicksTurn() {
        swipe(steps: 16, dx: -4, pause: 0.2)
        XCTAssertEqual(model.tab, .now, "64 pt, then the fingers stopped: back to Now")
        XCTAssertEqual(position, 0)
        swipe(steps: 4, dx: -12)
        XCTAssertEqual(model.tab, .backlog, "48 pt in 1/30 s is a flick")
        XCTAssertEqual(position, 1)
    }

    /// The tab follows the page both ways within one swipe.
    func testTheLiveTabFollowsTheFingersBack() {
        send(.began)
        for _ in 0..<5 { send(.changed, dx: -40) }
        XCTAssertEqual(model.tab, .backlog, "past halfway: Later")
        for _ in 0..<4 { send(.changed, dx: 40) }
        XCTAssertEqual(model.tab, .now, "back under halfway: Now again")
        send(.ended, gap: 0.3)
        XCTAssertEqual(model.tab, .now)
        XCTAssertEqual(position, 0)
    }

    /// The axis is decided on the first movement: a vertical gesture, and
    /// its momentum, are the list's entirely, even when it later drifts
    /// sideways; the page never moves.
    func testAVerticalScrollIsNeverTheLists() {
        XCTAssertFalse(send(.began))
        XCTAssertFalse(send(.changed, dx: 0, dy: -0))
        XCTAssertFalse(send(.changed, dx: -2, dy: -6))
        for _ in 0..<20 { XCTAssertFalse(send(.changed, dx: -30, dy: -2), "a drift sideways stays the list's") }
        XCTAssertFalse(send(.ended))
        for _ in 0..<10 { XCTAssertFalse(send(.none, dx: -30, momentum: true)) }
        XCTAssertEqual(model.tab, .now)
        XCTAssertEqual(position, 0)
        XCTAssertNil(swipe.axis)
    }

    /// A gesture that starts outside the lists (the header, the add bar,
    /// another page of the shell) or during a row drag is never a swipe.
    func testASwipeStartsOnlyOverTheListsAndNeverDuringADrag() {
        send(.began, allowed: false)
        for _ in 0..<20 { XCTAssertFalse(send(.changed, dx: -30)) }
        send(.ended)
        XCTAssertEqual(model.tab, .now)
        swipe.dragActive = true
        send(.began)
        for _ in 0..<20 { XCTAssertFalse(send(.changed, dx: -30)) }
        send(.ended)
        XCTAssertEqual(model.tab, .now, "no swipe during a drag")
        swipe.dragActive = false
    }

    /// A tab clicked during a swipe wins: the rest of the gesture and its
    /// momentum are ignored and nothing snaps back to the swipe's page.
    func testATabChosenDuringASwipeWins() throws {
        let task = try XCTUnwrap(store.create(title: "Call the plumber"))
        let routes: [(String, TasksTab, () -> Void)] = [
            ("Done's tab", .done, { self.model.select(tab: .done) }),
            ("the tab shown", .now, { self.model.select(tab: .now) }),
            ("show", .now, { _ = self.model.show(task.id) }),
            ("Search", .done, { self.model.beginSearch() }),
            ("a reveal", .now, { self.model.resetForReveal() })
        ]
        for (name, expected, route) in routes {
            model.select(tab: .now)
            model.showPagerPage(animated: false)
            send(.began)
            send(.changed, dx: -30)
            XCTAssertTrue(swipe.isTracking, name)
            route()
            XCTAssertEqual(swipe.axis, .cancelled, "\(name) ends the swipe")
            let before = position
            for _ in 0..<10 { XCTAssertTrue(send(.changed, dx: -40), "\(name): the rest of the gesture is ignored") }
            XCTAssertEqual(position, before, "\(name): the page no longer follows")
            send(.ended)
            for _ in 0..<5 { XCTAssertTrue(send(.none, dx: -40, momentum: true), "\(name): and its momentum") }
            XCTAssertEqual(model.tab, expected, "\(name) keeps its page")
            model.showPagerPage(animated: false)
            XCTAssertEqual(position, CGFloat(TasksTab.allCases.firstIndex(of: expected) ?? 0))
            model.clearSelection()
            model.doneSearch = ""
        }
        // The next gesture is a swipe again.
        model.select(tab: .now)
        model.showPagerPage(animated: false)
        swipe(steps: 10, dx: -40)
        XCTAssertEqual(model.tab, .backlog)
    }

    // MARK: - A wheel: one page per burst

    /// A mouse's horizontal wheel (or any scroll without trackpad phases,
    /// as UI tests synthesise): one page per burst however long it runs;
    /// the next burst turns the next page. A vertical wheel is the list's.
    func testAWheelTurnsOnePagePerBurst() {
        for _ in 0..<100 {
            XCTAssertTrue(send(.none, dx: -20, gap: 0.02))
        }
        XCTAssertEqual(model.tab, .backlog, "one burst of 2,000 pt: one page")
        XCTAssertEqual(position, 1)
        send(.none, dx: -20, gap: 1)
        XCTAssertEqual(model.tab, .done, "after a pause, the next")
        for _ in 0..<5 { send(.none, dx: -20, gap: 1) }
        XCTAssertEqual(model.tab, .done, "nothing past Done")
        XCTAssertFalse(send(.none, dx: 0, dy: -5, gap: 1), "a vertical wheel is the list's")
        XCTAssertTrue(send(.none, dx: 1, precise: false, gap: 1), "a line wheel's notch turns back")
        XCTAssertEqual(model.tab, .backlog)
        XCTAssertFalse(send(.none, dx: 20, gap: 1, allowed: false), "not over the lists: not the pager's")
    }

    // MARK: - Reduced motion: no travel

    /// With reduced motion the page does not travel with the fingers: past
    /// a quarter of a page it turns at once (a crossfade) and the rest of
    /// the gesture is ignored.
    func testReducedMotionTurnsThePageWithoutTravel() {
        swipe.reduced = true
        send(.began)
        send(.changed, dx: -40)
        XCTAssertEqual(position, 0, "no travel")
        XCTAssertEqual(model.tab, .now)
        send(.changed, dx: -40)
        XCTAssertEqual(model.tab, .backlog, "a quarter of a page turns it, while the fingers are down")
        XCTAssertEqual(position, 1)
        XCTAssertEqual(swipe.motion.fadingOut, 0, "Now fades out where it is")
        for _ in 0..<20 { XCTAssertTrue(send(.changed, dx: -40)) }
        send(.ended)
        XCTAssertEqual(model.tab, .backlog, "one page only")
        swipe.reduced = false
    }

    // MARK: - The real page

    /// Hosted as the panel hosts it: a swipe fed through the model lands
    /// the drawn page on Later, and a tab click still lands on its page.
    func testTheHostedPagerFollowsASwipeAndATab() throws {
        let hosted = try Hosted(height: 520)
        defer { hosted.close() }
        XCTAssertEqual(hosted.shownPage(), 0)
        XCTAssertGreaterThan(hosted.model.pagerSwipe.width, 0, "the page gave the pager its width")
        let model = hosted.model
        var time: TimeInterval = 0
        func send(_ phase: TasksPagerSwipe.Sample.Phase, dx: CGFloat = 0) {
            time += 1.0 / 120
            _ = model.pagerScrolled(.init(phase: phase, dx: dx, time: time), allowed: true)
        }
        send(.began)
        for _ in 0..<40 { send(.changed, dx: -30) }
        XCTAssertEqual(model.tab, .backlog, "the tab turned while the fingers were down")
        send(.ended)
        hosted.spin(1)
        XCTAssertEqual(hosted.shownPage(), 1)
        hosted.go(to: .done)
        XCTAssertEqual(hosted.shownPage(), 2)
        hosted.go(to: .now)
        XCTAssertEqual(hosted.shownPage(), 0, "Now from Done lands on Now")
    }

    // MARK: - Settings › Animations

    func testAnimationsIsASettingThatReducesMotion() throws {
        let suite = "attic.round9.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            AtticMotionPreference.level = .full
        }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.animations, .full, "Full by default")
        settings.animations = .reduced
        XCTAssertEqual(AppSettings(defaults: defaults).animations, .reduced, "remembered")
        XCTAssertTrue(AtticMotionPreference.reducesMotion, "code outside views reads it")
        settings.animations = .full
        XCTAssertEqual(AtticMotionPreference.level, .full)
        XCTAssertEqual(AtticAnimationLevel.allCases.map(\.title), ["Full", "Reduced"])
        XCTAssertNotEqual(SettingsVisibility.behaviourFootnote(systemReducesMotion: true),
                          SettingsVisibility.behaviourFootnote(systemReducesMotion: false),
                          "the footnote says when the Mac's Reduce Motion wins")
    }

    /// The design context reduces motion for Reduced as for the Mac's
    /// Reduce Motion, so every preset (and the Notes branch) follows it.
    func testReducedAnimationsReachTheDesignContext() throws {
        final class Probe { var reduceMotion: Bool? }
        let probe = Probe()
        struct Reader: View {
            let probe: Probe
            @Environment(\.atticDesign) private var design
            var body: some View {
                probe.reduceMotion = design.reduceMotion
                return Color.clear
            }
        }
        for (level, expected) in [(AtticAnimationLevel.full, false), (.reduced, true)] {
            probe.reduceMotion = nil
            let host = NSHostingView(rootView: Reader(probe: probe).atticDesignFromSystem(animations: level))
            host.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
            host.layoutSubtreeIfNeeded()
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                XCTAssertEqual(probe.reduceMotion, expected, "\(level)")
            }
        }
    }
}
