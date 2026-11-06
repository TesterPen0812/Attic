import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Attic

/// The owner's island and top-row refinements (Accepted 2026-11-05).
@MainActor
final class IslandTopRowRefineTests: XCTestCase {
    private func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// Glass renders as artefacts off screen; the solid surface does not.
    private var solid: AtticDesignContext {
        var context = AtticDesignContext.default
        context.reduceTransparency = true
        return context
    }

    private final class Offscreen {
        let host: NSHostingView<AnyView>
        let window: NSWindow

        @MainActor init<V: View>(_ view: V, size: CGSize, context: AtticDesignContext) {
            host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)
                .background(Color.white).atticDesign(context).environment(\.colorScheme, .light)))
            window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
        }

        @MainActor func close() {
            window.contentView = nil
            window.close()
        }

        /// One pixel row of the view as drawn now, a point per entry.
        @MainActor func row(y: CGFloat) throws -> [AtticRGBA] {
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / host.bounds.width
            return try (0..<Int(host.bounds.width)).map { x in
                let c = try XCTUnwrap(rep.colorAt(x: Int(CGFloat(x) * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
                return AtticRGBA(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
            }
        }
    }

    private func differs(_ a: AtticRGBA, _ b: AtticRGBA) -> Bool {
        max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue)) * 255 > 3
    }

    /// The furthest point right at which `now` differs from `rest`.
    private func reach(_ now: [AtticRGBA], from rest: [AtticRGBA]) -> Int {
        now.indices.last { $0 < rest.count && differs(now[$0], rest[$0]) } ?? 0
    }

    /// Runs `change`, and returns how far right the drawing differs from
    /// before it in each frame of the change, then once it has settled.
    private func reaches(_ view: Offscreen, y: CGFloat, change: () -> Void) throws -> (frames: [Int], settled: Int) {
        let rest = try view.row(y: y)
        change()
        var frames: [Int] = []
        for _ in 0..<20 {
            spin(0.012)
            frames.append(reach(try view.row(y: y), from: rest))
        }
        spin(0.5)
        return (frames, reach(try view.row(y: y), from: rest))
    }

    // MARK: Animated selection

    private final class TabHolder: ObservableObject { @Published var tab = TasksTab.now }

    private struct TabsHost: View {
        @ObservedObject var holder: TabHolder

        var body: some View {
            TasksTopTabs(selection: $holder.tab).padding(.leading, 10).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Now → Done: the marker crosses the middle tab on its way, which a
    /// crossfade between the two ends never would.
    func testTheTabsMarkerTravelsAcrossTheCellsBetween() throws {
        let holder = TabHolder()
        let view = Offscreen(TabsHost(holder: holder), size: CGSize(width: 200, height: 27), context: solid)
        defer { view.close() }
        spin(0.3)
        // Above the words, in the cells' top rows.
        let moved = try reaches(view, y: 6) { holder.tab = .done }
        XCTAssertGreaterThan(moved.settled, 40)
        XCTAssertTrue(moved.frames.contains { $0 > 8 && $0 < moved.settled - 8 },
                      "a frame draws the marker between the two tabs: \(moved.frames), settled \(moved.settled)")
    }

    // MARK: Compact tab switch

    func testOnlyTheCurrentTabOpensToItsName() {
        typealias M = TasksTopTabsMetrics
        for selection in TasksTab.allCases {
            for tab in TasksTab.allCases where tab != selection {
                XCTAssertEqual(M.cellWidth(tab, selection: selection), 21, "\(tab) shows only its icon")
            }
            XCTAssertEqual(M.cellWidth(selection, selection: selection), 21 + M.nameWidth(selection) + 7)
            XCTAssertLessThanOrEqual(M.width(selection: selection), M.slotWidth)
        }
        XCTAssertEqual(M.slotWidth, M.width(selection: .backlog), "the longest name sets the slot")
        XCTAssertLessThan(M.slotWidth, 134, "narrower than three words")
        let icons = TasksTab.allCases.map(\.systemName)
        XCTAssertEqual(Set(icons).count, icons.count)
        XCTAssertFalse(icons.contains(PanelPage.tasks.systemName), "no tab repeats the island's Tasks")
    }

    /// Where the capsule starts and ends on a row through its middle.
    private func capsuleEdges(_ row: [AtticRGBA]) throws -> (start: Int, end: Int) {
        let drawn = row.indices.filter { differs(row[$0], row[0]) }
        return (try XCTUnwrap(drawn.first), try XCTUnwrap(drawn.last))
    }

    /// Runs `change`, and returns the capsule's edges before it, in each
    /// frame of the change, and once it has settled.
    private func capsuleEdges(_ view: Offscreen, change: () -> Void) throws
        -> (rest: (start: Int, end: Int), frames: [(start: Int, end: Int)], settled: (start: Int, end: Int)) {
        let y = AtticControlSize.headerControl / 2
        let rest = try capsuleEdges(view.row(y: y))
        change()
        var frames: [(start: Int, end: Int)] = []
        for _ in 0..<20 {
            spin(0.012)
            frames.append(try capsuleEdges(view.row(y: y)))
        }
        spin(0.5)
        return (rest, frames, try capsuleEdges(view.row(y: y)))
    }

    /// Now → Backlog: the capsule opens by its left edge a step at a time,
    /// and its right edge, beside •••, never moves.
    func testTheCapsuleOpensLeftwardsWithNoJump() throws {
        let holder = TabHolder()
        let view = Offscreen(TabsHost(holder: holder), size: CGSize(width: 200, height: 27), context: solid)
        defer { view.close() }
        spin(0.3)
        let change = try capsuleEdges(view) { holder.tab = .backlog }
        let travel = change.rest.start - change.settled.start
        let expected = TasksTopTabsMetrics.width(selection: .backlog) - TasksTopTabsMetrics.width(selection: .now)
        XCTAssertEqual(CGFloat(travel), expected, accuracy: 1.5)
        XCTAssertTrue(change.frames.contains { $0.start > change.settled.start + 1 && $0.start < change.rest.start - 1 },
                      "a frame draws the capsule part way: \(change.frames.map(\.start))")
        let starts = [change.rest.start] + change.frames.map(\.start)
        let steps = zip(starts, starts.dropFirst()).map { abs($0 - $1) }
        XCTAssertLessThan(steps.max() ?? 0, travel, "never the whole way in a frame: \(starts)")
        for frame in change.frames { XCTAssertEqual(frame.end, change.rest.end, accuracy: 1, "the right edge stays") }
    }

    func testTheCapsuleResizesAtOnceUnderReduceMotion() throws {
        var reduced = solid
        reduced.reduceMotion = true
        let holder = TabHolder()
        let view = Offscreen(TabsHost(holder: holder), size: CGSize(width: 200, height: 27), context: reduced)
        defer { view.close() }
        spin(0.3)
        let change = try capsuleEdges(view) { holder.tab = .backlog }
        XCTAssertLessThan(change.settled.start, change.rest.start)
        XCTAssertFalse(change.frames.contains { $0.start > change.settled.start + 1 && $0.start < change.rest.start - 1 },
                       "\(change.frames.map(\.start))")
    }

    private final class TagHolder: ObservableObject { @Published var tag: String? }

    private struct TagsHost: View {
        @ObservedObject var holder: TagHolder

        var body: some View {
            NotesTagBar(tags: ["aaaa", "bbbb", "cccc", "dddd"], selection: holder.tag, onSelect: { holder.tag = $0 })
        }
    }

    func testTheTagBarsMarkerTravelsAcrossThePillsBetween() throws {
        let holder = TagHolder()
        let view = Offscreen(TagsHost(holder: holder), size: CGSize(width: 320, height: 27), context: solid)
        defer { view.close() }
        spin(0.3)
        let rest = try view.row(y: 5)
        let layer = try XCTUnwrap(view.host.layer)
        let start = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
        layer.timeOffset = start
        defer { layer.speed = 1; layer.timeOffset = 0 }
        view.host._renderForTest(interval: 0)
        holder.tag = "dddd"
        var frames: [[AtticRGBA]] = []
        for step in 0...24 {
            // SwiftUI's 200 ms travel spring is sampled on a fixed clock;
            // bitmap capture on a slow CI runner cannot skip the middle.
            view.host._renderForTest(interval: step == 0 ? 0 : 1.0 / 60)
            layer.timeOffset = start + Double(step) / 60
            CATransaction.flush()
            frames.append(try view.row(y: 5))
        }
        layer.speed = 1
        layer.timeOffset = 0
        spin(0.5)
        let settled = try view.row(y: 5)
        XCTAssertGreaterThan(reach(settled, from: rest), 60)
        // The chosen tag also changes font weight at the far right. Counting
        // the last changed pixel would always report that text, including
        // while the marker crosses the unchanged middle pills.
        let middle = 60..<160
        XCTAssertTrue(frames.contains { frame in
            middle.contains { x in differs(frame[x], rest[x]) && !differs(settled[x], rest[x]) }
        }, "a frame draws the marker between All and dddd, away from text that changes permanently")
    }

    func testTheMarkerMovesAtOnceUnderReduceMotion() throws {
        var reduced = solid
        reduced.reduceMotion = true
        XCTAssertNil(AtticSelectionMarker.travel(reduceMotion: true))
        let holder = TabHolder()
        let view = Offscreen(TabsHost(holder: holder), size: CGSize(width: 200, height: 27), context: reduced)
        defer { view.close() }
        spin(0.3)
        let moved = try reaches(view, y: 6) { holder.tab = .done }
        XCTAssertFalse(moved.frames.contains { $0 > 8 && $0 < moved.settled - 8 }, "\(moved.frames)")
    }

    /// Hover and selection stay distinct, and the hover's chip fades in
    /// where the pointer arrives rather than flying in from where it was.
    func testTheHoverChipTravelsAlongTheSwitchAndFadesOnAndOff() {
        typealias Step = AtticHoverChip.Step
        let a = CGRect(x: 0, y: 0, width: 21, height: 21), b = CGRect(x: 22, y: 0, width: 21, height: 21)
        XCTAssertEqual(Step.next(from: nil, to: a, shown: true), Step(place: a, travels: false, visible: true))
        XCTAssertEqual(Step.next(from: a, to: b, shown: true), Step(place: b, travels: true, visible: true))
        XCTAssertEqual(Step.next(from: a, to: b, shown: false), Step(place: b, travels: true, visible: false),
                       "on the current choice only the marker shows")
        XCTAssertEqual(Step.next(from: b, to: nil, shown: true), Step(place: nil, travels: false, visible: false),
                       "it fades where it was")
        XCTAssertLessThan(AtticSelectionMarker.hoverAlpha, AtticSelectionMarker.fillAlpha)
    }

    // MARK: Header spacing

    func testTheTopRowKeepsTheSwitchApartFromItsIcons() {
        let layout = PanelPageLayout(cornerSize: 24, panelSize: CGSize(width: 340, height: 600))
        let search = PanelTopRowLayout.searchButtonFrame(layout), more = PanelTopRowLayout.moreButtonFrame(layout)
        let tabs = PanelTopRowLayout.switchFrame(layout, width: 100)
        XCTAssertEqual(search.minX - more.maxX, TasksDesignMetrics.footerGap, "the bottom bar's gap")
        XCTAssertEqual(more.minX - tabs.maxX, 2 * TasksDesignMetrics.footerGap)
        XCTAssertEqual(tabs.height, more.height, "one line")
        XCTAssertEqual(tabs.minY, more.minY)
    }

    // MARK: Settings in the island

    func testSettingsIsTheIslandsLastItemAndNeverAPage() {
        typealias L = PanelIslandLayout
        XCTAssertEqual(L.items.last, .settings)
        XCTAssertEqual(L.items.count, L.pages.count + 1)
        XCTAssertEqual(L.height(), 126, "3 + 5 × 21 + 4 × 3 + 3 + 3")
        XCTAssertEqual(L.flatLength(), 146, "3 + 5 × 25 + 4 × 3 + 3 + 3")
        XCTAssertEqual(L.restDots(current: 0).count, L.pages.count, "a dot per page, none for Settings")

        for size in [CGSize(width: 27, height: L.height()), CGSize(width: L.flatLength(), height: 27)] {
            let island = CGRect(origin: .zero, size: size)
            let lastPage = L.itemFrame(L.pages.count - 1, in: island), settings = L.itemFrame(L.pages.count, in: island)
            XCTAssertTrue(island.insetBy(dx: L.inset - 0.01, dy: L.inset - 0.01).contains(settings), "inside the capsule's inset")
            let apart = size.width > size.height ? settings.minX - lastPage.maxX : lastPage.minY - settings.maxY
            XCTAssertEqual(apart, L.gap + L.settingsExtraGap)
            XCTAssertNil(PanelIslandPullTracker.page(at: CGPoint(x: settings.midX, y: settings.midY), in: island),
                         "Settings can't be pulled out")
        }
    }

    func testTheIslandsSettingsItemOpensSettingsAndNeverSwitchesPage() {
        var delays: [() -> Void] = []
        let island = PanelIslandModel(schedule: { _, run in delays.append(run) })
        var opened = 0, requests = 0, clicks = 0
        island.onOpenSettings = { opened += 1 }
        island.onClick = { clicks += 1 }
        let subscription = island.requests.sink { _ in requests += 1 }
        defer { subscription.cancel() }

        island.clickSettings()
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(clicks, 0, "the page switch's activation is not Settings'")
        XCTAssertEqual(island.page, .tasks)

        island.suppressesClicks = true
        island.clickSettings()
        XCTAssertEqual(opened, 1, "the end of a pull is not a click")
    }

    func testPointingAtSettingsNamesItLikeAPage() {
        var delays: [() -> Void] = []
        let island = PanelIslandModel(schedule: { _, run in delays.append(run) })
        island.point(atItem: .settings)
        XCTAssertEqual(island.pointedItem, .settings)
        XCTAssertNil(island.pointed, "not a page")
        XCTAssertNil(island.labelItem, "the first name waits")
        delays.forEach { $0() }
        XCTAssertEqual(island.labelItem, .settings)
        XCTAssertEqual(island.labelItem?.title, "Settings")
        island.point(at: .notes)
        XCTAssertEqual(island.labelPage, .notes, "moving on: at once")
        island.leave(item: .settings)
        XCTAssertEqual(island.pointed, .notes, "leaving an item the pointer already left changes nothing")
    }

    // MARK: Page-specific options

    private func titles(_ commands: [AtticMenuCommand]) -> [String] { commands.map(\.title) }

    func testTheChromeHandsOutWhatTheCurrentPageOffers() {
        let chrome = PanelSharedChrome()
        XCTAssertTrue(chrome.more(on: .tasks).isEmpty)
        var built = 0
        chrome.setMore({ built += 1; return [AtticMenuCommand(verbatim: "One") {}] }, for: .tasks)
        XCTAssertEqual(built, 0, "built when it opens")
        XCTAssertEqual(titles(chrome.more(on: .tasks)), ["One"])
        XCTAssertTrue(chrome.more(on: .notes).isEmpty, "each page its own")
        chrome.removeTopRow(for: .tasks)
        XCTAssertTrue(chrome.more(on: .tasks).isEmpty)
    }

    func testCalendarOffersTheViewsItHas() {
        var asked: [Bool] = [], today = 0
        let commands = CalendarPage.moreCommands(isWeekView: true, isOnToday: false, setWeekView: { asked.append($0) },
                                                 goToToday: { today += 1 })
        XCTAssertEqual(titles(commands), ["View", "Month", "Week", "Go to Today"], "no Day: the page has no such view")
        XCTAssertEqual(commands[1].state, .off)
        XCTAssertEqual(commands[2].state, .on)
        commands[1].action()
        commands[3].action()
        XCTAssertEqual(asked, [false])
        XCTAssertEqual(today, 1)
        let onToday = CalendarPage.moreCommands(isWeekView: false, isOnToday: true, setWeekView: { _ in }, goToToday: {})
        XCTAssertEqual(onToday[1].state, .on)
        XCTAssertTrue(onToday[3].isDisabled)
    }

    func testTheNotesListOffersItsLayoutsAndItsHistory() {
        var chosen: [NotesLibraryLayout] = []
        let history = [AtticMenuCommand(verbatim: "Undo", startsSection: true) {}]
        let commands = NotesEditorPage.libraryMoreCommands(layout: .list, history: history) { chosen.append($0) }
        XCTAssertEqual(titles(commands), ["View", "Board", "List", "Undo"])
        XCTAssertEqual(commands[2].state, .on)
        commands[1].action()
        XCTAssertEqual(chosen, [.board])
    }

    // MARK: Later becomes Backlog

    func testTheBacklogIsNamedBacklogEverywhereItShows() {
        XCTAssertEqual(TasksTab.backlog.title, "Backlog")
        XCTAssertEqual(TasksTab.backlog.identifier, "backlog", "the identifier stays")
        XCTAssertEqual(PanelSection.backlog.title, "Backlog")
        XCTAssertEqual(PanelSection.backlog.rawValue, "backlog", "the stored value stays")
        XCTAssertEqual(TaskStatus.backlog.menuTitle, "Backlog")
        XCTAssertEqual(TaskStatus.backlog.rawValue, "backlog", "the stored value stays")
    }

    func testTheBacklogListSitsUnderOneNoDateHeading() throws {
        let ids = [UUID(), UUID()]
        let group = try XCTUnwrap(TasksPanelDesign.backlogGroups(ids).first)
        XCTAssertEqual(group.title, "No date")
        XCTAssertTrue(group.showsHeader)
        XCTAssertTrue(group.rowsShowDate, "a row with a date would still show it")
        XCTAssertEqual(group.ids, ids, "the list's order")
        XCTAssertTrue(TasksPanelDesign.backlogGroups([]).isEmpty, "no heading over an empty list")
    }

    func testDrawOffersWhatTheBoardAndCanvasDo() {
        let model = DrawPageModel(store: DrawInMemoryStore())
        let commands = model.moreCommands()
        XCTAssertEqual(titles(commands), ["Zoom to Fit", "Actual Size", "Select All", "New Canvas", "Copy as Image", "Export…"])
        XCTAssertEqual(commands.filter(\.isDisabled).map(\.title), ["Zoom to Fit", "Select All", "Copy as Image", "Export…"],
                       "nothing on the board yet")
    }
}
