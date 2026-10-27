import AppKit
import SwiftData
import XCTest
@testable import Attic

/// The owner's own panel design (Claude Design, 2026-10-27), built on the
/// branch's model: date groups per page (and at midnight), Done's day
/// headers and folds, a finished task leaving Now, the tag pill's colours,
/// the footer's turn, the empty states, the filter chips and the design's
/// sizes (drawn at 2×, px ÷ 2 = pt).
@MainActor
final class TasksPanelDesignTests: XCTestCase {
    /// Mon 21 Sep 2026, 14:13 UTC.
    private let clock = MutableNow(Date(timeIntervalSince1970: 1_790_000_000))
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let locale = Locale(identifier: "en_GB")
    private var store: TaskStore!
    private var library: AtticLibrary!
    private var model: TasksPageModel!

    override func setUp() async throws {
        store = try makeTestStore(now: { [clock] in clock.value })
        library = AtticLibrary(tasks: store, now: { [clock] in clock.value })
        let calendar = self.calendar
        model = TasksPageModel(library: library, services: TasksPageServices(
            now: { [clock] in clock.value }, calendar: { calendar }, locale: locale, doneHold: .seconds(3_600)))
        model.toasts.holdDuration = 3_600
    }

    override func tearDown() {
        model = nil
        library = nil
        store = nil
    }

    private func day(_ offset: Int) -> DueDay {
        DueDay(date: calendar.date(byAdding: .day, value: offset, to: clock.value)!, calendar: calendar)
    }

    @discardableResult
    private func add(_ title: String, due offset: Int?, tab: TasksTab = .now) throws -> UUID {
        model.select(tab: tab)
        model.addBar.text = title
        let id = try XCTUnwrap(model.submitAddBar())
        if let offset { XCTAssertTrue(model.setDueDay(day(offset), for: [id]).isApplied) }
        return id
    }

    private func titles(_ tab: TasksTab) -> [String] { model.rows(for: tab).map(\.model.title) }
    private func headers(_ tab: TasksTab) -> [String] { model.sections(for: tab).groups.map(\.title) }

    // MARK: - Date groups

    func testGroupsAreOverdueTodayEachLaterDayThenNoDate() {
        let today = day(0)
        let ids = (0..<6).map { _ in UUID() }
        let rows: [(id: UUID, due: DueDay?)] = [(ids[0], nil), (ids[1], day(3)), (ids[2], day(-2)), (ids[3], today),
                                                 (ids[4], day(1)), (ids[5], day(-1))]
        let groups = TasksPanelDesign.groups(rows, today: today, calendar: calendar, locale: locale)
        XCTAssertEqual(groups.count, 5)
        XCTAssertEqual(groups.map(\.title).filter { !$0.hasPrefix("Thu 24 Sep") }, ["Overdue", "Today", "Tomorrow", "No date"])
        XCTAssertTrue(groups[3].title.hasPrefix("Thu 24 Sep"), "a later day's header: \(groups[3].title)")
        XCTAssertEqual(groups[0].ids, [ids[2], ids[5]], "the list's own order inside a group")
        XCTAssertEqual(groups.map(\.rowsShowDate), [true, true, false, false, true], "a day header carries the date")
        XCTAssertTrue(groups[0].isOverdue)
    }

    func testNowAndLaterListRowsInGroupOrderAndDayHeadersHideTheRowDate() throws {
        try add("Undated", due: nil)
        try add("Next", due: 1)
        try add("Late", due: -3)
        try add("Current", due: 0)
        XCTAssertEqual(headers(.now), ["Overdue", "Today", "Tomorrow", "No date"])
        XCTAssertEqual(titles(.now), ["Late", "Current", "Next", "Undated"], "the keyboard walks the groups' order")
        let tomorrow = try XCTUnwrap(model.rows(for: .now).first { $0.model.title == "Next" })
        XCTAssertNil(tomorrow.model.due, "under a day header a row shows no date (Attic's tasks have no time)")
        XCTAssertEqual(model.rows(for: .now).first?.model.due?.tone, .overdue)
        try add("Idea", due: 5, tab: .backlog)
        try add("Someday", due: nil, tab: .backlog)
        XCTAssertEqual(headers(.backlog).last, "No date")
        XCTAssertEqual(headers(.backlog).count, 2)
    }

    func testAHeaderFoldsItsGroupAndTheFoldIsPerPage() throws {
        try add("Late", due: -1)
        try add("Plain", due: nil)
        let overdue = try XCTUnwrap(model.sections(for: .now).groups.first)
        model.toggleGroup(overdue.key, on: .now)
        XCTAssertEqual(titles(.now), ["Plain"], "a folded group's rows leave the list")
        XCTAssertEqual(model.sections(for: .now).groups.map(\.title), ["Overdue", "No date"], "its header stays")
        XCTAssertEqual(model.sections(for: .now).groups.first?.ids.count, 1, "the count it shows while folded")
        XCTAssertTrue(model.folded(on: .backlog).isEmpty)
        model.toggleGroup(overdue.key, on: .now)
        XCTAssertEqual(titles(.now), ["Late", "Plain"])
    }

    func testGroupsMoveOnAtMidnight() throws {
        try add("Soon", due: 1)
        XCTAssertEqual(headers(.now), ["Tomorrow"])
        clock.value = calendar.date(byAdding: .day, value: 1, to: clock.value)!
        XCTAssertEqual(headers(.now), ["Today"], "the rows cache is keyed by the day")
        clock.value = calendar.date(byAdding: .day, value: 1, to: clock.value)!
        XCTAssertEqual(headers(.now), ["Overdue"])
    }

    func testAKeyboardMoveStaysInsideItsDateGroup() throws {
        let a = try add("A", due: nil)
        let b = try add("B", due: -1)
        let c = try add("C", due: nil)
        XCTAssertEqual(Set(model.shownGroup(of: a, status: .todo, on: .now)), [a, c])
        XCTAssertEqual(model.shownGroup(of: b, status: .todo, on: .now), [b])
        XCTAssertNotEqual(model.groupKey(of: a, on: .now), model.groupKey(of: b, on: .now))
    }

    // MARK: - Done

    func testDoneDaysUseTheDesignsHeadersAndFold() throws {
        let id = try add("Finished", due: nil)
        XCTAssertTrue(model.toggleDone(id).isApplied)
        model.releaseHold(id)
        let days = model.doneDays()
        XCTAssertEqual(days.first?.title.hasPrefix("Mon 21 Sep"), true, "today's header is its date too: \(days.first?.title ?? "")")
        let key = try XCTUnwrap(days.first?.key)
        model.toggleGroup(key, on: .done)
        XCTAssertEqual(model.doneDays().first?.rows.count, 0)
        XCTAssertEqual(model.doneDays().first?.total, 1)
        XCTAssertEqual(model.doneDays().first?.folded, true)
    }

    func testAFinishedTaskLeavesNowAfterItsHoldAndUndoBringsItBack() throws {
        try add("First", due: nil)
        let done = try add("Second", due: nil)
        try add("Third", due: nil)
        let before = titles(.now)
        XCTAssertTrue(model.toggleDone(done).isApplied)
        XCTAssertEqual(titles(.now), before, "it holds its place while the ring plays")
        model.releaseHold(done)
        XCTAssertFalse(titles(.now).contains("Second"), "then it leaves Now")
        XCTAssertTrue(model.sections(for: .now).done.isEmpty, "Now has no Completed today")
        XCTAssertEqual(model.completedTodayCount, 0)
        XCTAssertTrue(model.doneDays().flatMap(\.rows).contains { $0.id == done }, "it lives in Done")
        XCTAssertTrue(model.undo().isApplied)
        XCTAssertEqual(titles(.now), before, "undo brings it back to the same place")
    }

    // MARK: - Pure rules

    func testTagPillsAreTheDesignsOklchPairInTheTagsOwnHue() {
        let blue = TasksPanelDesign.tagColours(hue: TasksPanelDesign.oklchHue(for: .blue), dark: false)
        func rgb(_ c: AtticRGBA) -> [Int] { [c.red, c.green, c.blue].map { Int(($0 * 255).rounded()) } }
        XCTAssertEqual(rgb(blue.text), [0, 90, 157], "oklch(0.46 0.13 250)")
        XCTAssertEqual(rgb(blue.fill), [209, 224, 240], "oklch(0.9 0.028 250)")
        XCTAssertEqual(rgb(TasksPanelDesign.tagColours(hue: TasksPanelDesign.oklchHue(for: .pink), dark: false).text), [133, 53, 110])
        XCTAssertNil(TasksPanelDesign.oklchHue(for: .grey))
        XCTAssertEqual(TasksPanelDesign.oklchHue(for: .indigo), 250, "a legacy colour shows as its clear hue")
        let dark = TasksPanelDesign.tagColours(hue: 250, dark: true)
        XCTAssertGreaterThan(dark.text.relativeLuminance, dark.fill.relativeLuminance, "dark mode: light text on a deep fill")
    }

    func testTheFooterTurnsWhileTheAddFieldIsUsed() {
        XCTAssertFalse(TasksPanelDesign.footerFolded(addFocused: false, hasDraft: false))
        XCTAssertTrue(TasksPanelDesign.footerFolded(addFocused: true, hasDraft: false))
        XCTAssertTrue(TasksPanelDesign.footerFolded(addFocused: false, hasDraft: true), "a kept draft keeps the field wide")
    }

    func testEmptyStatesUseTheDesignsCopy() {
        XCTAssertEqual(TasksPanelDesign.empty(tab: .now, query: "", filtered: false).title, "Nothing to do right now")
        XCTAssertEqual(TasksPanelDesign.empty(tab: .backlog, query: "", filtered: false).title, "Nothing scheduled")
        XCTAssertEqual(TasksPanelDesign.empty(tab: .done, query: "", filtered: false),
                       .init(title: "Nothing completed yet", body: "Tasks you check off show up here.", canClear: false))
        XCTAssertEqual(TasksPanelDesign.empty(tab: .now, query: " milk ", filtered: false),
                       .init(title: "No results", body: "No tasks match “milk”.", canClear: true))
        XCTAssertEqual(TasksPanelDesign.empty(tab: .backlog, query: "", filtered: true).canClear, true)
    }

    func testFilterChipsAreTheViewOptionsFiltersAndKeepTheSort() {
        XCTAssertEqual(TasksPanelDesign.chips.first?.title, "All")
        var view = TasksViewOptions()
        view.sort = .priority
        XCTAssertEqual(TasksPanelDesign.selectedChip(for: view)?.id, "all")
        let overdue = TasksPanelDesign.chips.first { $0.id == "overdue" }!
        let next = TasksPanelDesign.view(choosing: overdue, from: view)
        XCTAssertEqual(next.show, .overdueOnly)
        XCTAssertEqual(next.sort, .priority, "a chip never changes the sort")
        XCTAssertEqual(TasksPanelDesign.selectedChip(for: next)?.id, "overdue")
        var mixed = TasksViewOptions()
        mixed.show = .overdueOnly
        mixed.priority = .highOnly
        XCTAssertNil(TasksPanelDesign.selectedChip(for: mixed), "a mix from the menu lights no chip")
    }

    // MARK: - The design's sizes (px ÷ 2)

    func testTheDesignsSizes() {
        XCTAssertEqual(AtticControlSize.headerControl, 27, "54 px header controls")
        XCTAssertEqual(AtticControlSize.addBarHeight, 30.5, "61 px add field")
        XCTAssertEqual(AtticPageButton<PanelPage>.width(open: false, count: 3), 36, "72 px shut")
        XCTAssertEqual(AtticPageButton<PanelPage>.width(open: true, count: 3), 75, "150 px open")
        XCTAssertEqual(TasksRowDesign.height(twoLine: false, tiles: false), 29, "7 + 15 + 7")
        XCTAssertEqual(TasksRowDesign.height(twoLine: true, tiles: false), 45.5, "with the meta line")
        XCTAssertEqual(TasksRowDesign.height(twoLine: true, tiles: true), 78.5, "with a line of 28 pt tiles")
        XCTAssertEqual(TasksRowDesign.radius, 12)
        XCTAssertEqual(AtticTextStyle.taskTitle.spec.size, 12)
        XCTAssertEqual(AtticTextStyle.taskTitle.spec.weight, .medium)
        XCTAssertEqual(AtticTextStyle.taskDate.spec.size, 10)
        XCTAssertTrue(AtticTextStyle.taskDate.spec.monospacedDigits)
        XCTAssertEqual(AtticTextStyle.priorityMark.spec.weight, .bold)
        XCTAssertEqual(AtticStatusCircleMetrics.ringWidth(increaseContrast: false), 0.8)
        XCTAssertEqual(AtticStatusCircleMetrics.ringWidth(increaseContrast: true), 2, "Increase Contrast keeps its ring")
        XCTAssertEqual(TasksDesignMetrics.tabCell * 3 + TasksDesignMetrics.tabsGap * 2 + TasksDesignMetrics.tabsPadding * 2, 85.5)
        XCTAssertEqual(TasksPanelDesign.tileLabel("Last invoice.pdf"), "PDF")
    }

    /// Fix round 1: the chips belong to the open search; after it closes
    /// they stay only while a filter hides tasks.
    func testTheChipsLeaveWithTheSearchUnlessAFilterHidesTasks() {
        XCTAssertTrue(TasksPanelDesign.chipsShown(tab: .now, chipsOpen: true, searchShown: true, filtering: false))
        XCTAssertFalse(TasksPanelDesign.chipsShown(tab: .now, chipsOpen: true, searchShown: false, filtering: false),
                       "the filter button's chips outlived the search")
        XCTAssertTrue(TasksPanelDesign.chipsShown(tab: .backlog, chipsOpen: false, searchShown: false, filtering: true))
        XCTAssertFalse(TasksPanelDesign.chipsShown(tab: .done, chipsOpen: true, searchShown: true, filtering: true))
    }
}
