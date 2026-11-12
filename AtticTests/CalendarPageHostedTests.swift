import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import Attic

@MainActor
private final class CalendarVisibilityProbe: ObservableObject {
    @Published var onScreen = false
}

@MainActor
private final class CalendarAccessProbe: CalendarEventSource {
    var accessState: CalendarAccessState = .notDetermined
    var onChange: (@MainActor () -> Void)?
    private(set) var requests = 0
    func requestAccess() async -> CalendarAccessState {
        requests += 1
        accessState = .denied
        return .denied
    }
    func events(in interval: DateInterval) -> [CalendarEvent] { [] }
    func search(_ text: String, in interval: DateInterval) -> [CalendarEvent] { [] }
}

private struct CalendarVisibilityProbeView: View {
    @ObservedObject var probe: CalendarVisibilityProbe
    let model: CalendarPageModel

    var body: some View {
        CalendarPage(model: model, layout: PanelPageLayout(cornerSize: 28, panelSize: CGSize(width: 320, height: 460)),
                     taskActions: CalendarTaskRowActions(toggleDone: { _ in }, open: { _ in }), onNewTask: { _ in },
                     panelIsVisible: probe.onScreen)
            .atticDesign(AtticDesignContext(mode: .light))
            .frame(width: 320, height: 460)
    }
}

/// The Calendar page mounted in an off-screen window (Accepted 2026-10-30,
/// "Calendar page"): what the page itself shows and does, not only its
/// helpers. Today in the bottom bar comes and goes with the selection,
/// every day keeps its own date tile (empty days too, owner 2026-10-31: the
/// older agenda) and a tile selects its day, and events loading keep the
/// tiles, the selection and the scroll position while the page updates a
/// bounded number of times.
@MainActor
final class CalendarPageHostedTests: XCTestCase {
    private let calendar = CalendarMonthMath.calendar(timeZone: TimeZone(identifier: "Europe/London")!)

    func testR15PrewarmedCalendarRequestsPermissionOnlyWhenPanelAppears() throws {
        let store = try makeTestStore()
        let source = CalendarAccessProbe()
        let model = CalendarPageModel(store: store, source: source, calendar: calendar,
                                      now: { self.date(2026, 10, 29, 12) })
        let visible = CalendarVisibilityProbe()
        let size = CGSize(width: 320, height: 460)
        let host = NSHostingView(rootView: CalendarVisibilityProbeView(probe: visible, model: model))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(source.requests, 0, "prewarming a selected Calendar behind a hidden panel does not prompt")
        visible.onScreen = true
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(source.requests, 1, "an actual panel reveal requests permission once")
        visible.onScreen = false
        visible.onScreen = true
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(source.requests, 1, "another reveal does not re-request permission")
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> DueDay { DueDay(year: y, month: m, day: d)! }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func event(_ id: String, on d: Int, month m: Int = 10, hour h: Int = 9) -> CalendarEvent {
        CalendarEvent(id: id, title: "Event \(id)", start: date(2026, m, d, h), end: date(2026, m, d, h + 1),
                      isAllDay: false, location: nil, calendarTitle: "Home",
                      colour: CalendarEventColour(red: 0.2, green: 0.5, blue: 0.9))
    }

    // MARK: - Today

    func testTodayButtonIsAbsentOnTodayAndPresentOnAnotherDay() throws {
        try withPage(events: [event("s", on: 29)]) { page in
            XCTAssertEqual(page.model.snapshot.selected, day(2026, 10, 29))
            XCTAssertNil(page.element("calendar-today"), "today selected: no Today button")
            page.model.select(day(2026, 10, 31))
            page.settle()
            let today = try XCTUnwrap(page.element("calendar-today"), "another day selected: Today shows")
            XCTAssertTrue(today.accessibilityPerformPress?() ?? false, "Today takes a click")
            page.settle(0.6)
            XCTAssertEqual(page.model.snapshot.selected, day(2026, 10, 29), "Today goes to today")
            XCTAssertNil(page.element("calendar-today"), "back on today, the button goes again")
        }
    }

    func testSearchFoldsToSelectedWeekAndClosingRestoresMonth() throws {
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = true
        defer {
            AtticMotionPreference.systemReduceMotionOverride = nil
            AtticTransparencySeam.systemOverride = nil
        }
        try withPage(events: []) { page in
            XCTAssertTrue(try XCTUnwrap(page.element("calendar-search-button")).accessibilityPerformPress?() ?? false)
            page.settle()
            XCTAssertEqual(page.offset, CalendarMonthMath.weekViewOffset(weekCount: page.model.snapshot.weeks.count), accuracy: 0.5)
            XCTAssertNotNil(page.element("calendar-search"))
            XCTAssertTrue(try XCTUnwrap(page.element(label: "End search")).accessibilityPerformPress?() ?? false)
            page.settle()
            XCTAssertEqual(page.offset, 0, accuracy: 0.5)
        }
    }

    func testTodayIsBetweenTheArrowsAndNeverInTheBottomBar() throws {
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = true
        defer {
            AtticMotionPreference.systemReduceMotionOverride = nil
            AtticTransparencySeam.systemOverride = nil
        }
        try withPage(events: []) { page in
            page.model.select(day(2026, 9, 30))
            page.settle()
            @MainActor func frame(_ id: String) throws -> CGRect {
                try XCTUnwrap((page.element(id) as? NSAccessibilityElementProtocol)?.accessibilityFrame())
            }
            let previous = try frame("calendar-previous"), today = try frame("calendar-today"), next = try frame("calendar-next")
            XCTAssertEqual(page.matching("calendar-today").count, 1, "no second Today remains in the footer")
            XCTAssertEqual(today.midY, previous.midY, accuracy: 0.5)
            // Arrow hit targets extend 3.5 pt beyond their 21 pt faces.
            // Assert the faces' exact spacing, rather than their hit halos.
            let step = 21.0 / 2 + 1 + 44.0 / 2
            XCTAssertEqual(today.midX - previous.midX, step, accuracy: 0.5)
            XCTAssertEqual(next.midX - today.midX, step, accuracy: 0.5)
            XCTAssertEqual(next.midY, previous.midY, accuracy: 0.5)
        }
    }

    func testAnExternalEventOpensReadOnlyAndOnlyOneRowOpens() throws {
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = true
        defer {
            AtticMotionPreference.systemReduceMotionOverride = nil
            AtticTransparencySeam.systemOverride = nil
        }
        try withPage(events: [event("one", on: 29), event("two", on: 29, hour: 11)]) { page in
            let head = try XCTUnwrap((page.element("calendar-event-one") as? NSAccessibilityElementProtocol)?.accessibilityFrame())
            let point = page.window.convertPoint(fromScreen: CGPoint(x: head.maxX - 2, y: head.midY))
            page.click(at: point, count: 1)
            page.settle()
            XCTAssertNotNil(page.element("calendar-event-open-one"))
            XCTAssertNotNil(page.element("calendar-event-duration-one"))
            XCTAssertNil(page.element("calendar-event-delete-one"))
            XCTAssertNil(page.element("calendar-event-title-one"))
            XCTAssertTrue(try XCTUnwrap(page.element("calendar-event-two")).accessibilityPerformPress?() ?? false)
            page.settle()
            XCTAssertNil(page.element("calendar-event-open-one"))
            XCTAssertNotNil(page.element("calendar-event-open-two"))
        }
    }

    func testAMultiDayEventOpensOnlyTheClickedDayRow() throws {
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = true
        defer {
            AtticMotionPreference.systemReduceMotionOverride = nil
            AtticTransparencySeam.systemOverride = nil
        }
        var span = event("span", on: 29)
        span.isAllDay = true
        span.start = date(2026, 10, 29)
        span.end = date(2026, 10, 31)
        try withPage(events: [span]) { page in
            XCTAssertEqual(page.matching("calendar-event-span").count, 2)
            XCTAssertTrue(try XCTUnwrap(page.matching("calendar-event-span").first).accessibilityPerformPress?() ?? false)
            page.settle()
            XCTAssertEqual(page.matching("calendar-event-open-span").count, 1, "one physical day row opens")
            XCTAssertTrue(try XCTUnwrap(page.matching("calendar-event-span").last).accessibilityPerformPress?() ?? false)
            page.settle()
            XCTAssertEqual(page.matching("calendar-event-open-span").count, 1, "opening the other day closes the first")
        }
    }

    func testCommandTReturnsToTodayAndEscapeClosesOnlyTheOpenEvent() throws {
        try requireKeyWindowTests()
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = false
        defer {
            AtticMotionPreference.systemReduceMotionOverride = nil
            AtticTransparencySeam.systemOverride = nil
        }
        try withPage(events: [event("keys", on: 29)], keyWindow: true) { page in
            page.model.select(day(2026, 10, 31)); page.settle()
            page.press("t", keyCode: 17, modifiers: [.command, .shift])
            XCTAssertEqual(page.model.snapshot.selected, day(2026, 10, 31))
            page.press("t", keyCode: 17, modifiers: .command)
            XCTAssertEqual(page.model.snapshot.selected, day(2026, 10, 29))
            XCTAssertTrue(try XCTUnwrap(page.element("calendar-event-keys")).accessibilityPerformPress?() ?? false)
            page.settle()
            XCTAssertNotNil(page.element("calendar-event-open-keys"))
            page.press("\u{1b}", keyCode: 53)
            XCTAssertNil(page.element("calendar-event-open-keys"))
            XCTAssertNotNil(page.element("calendar-event-keys"))
            XCTAssertTrue(try XCTUnwrap(page.element("calendar-search-button")).accessibilityPerformPress?() ?? false)
            page.settle()
            XCTAssertEqual(page.offset, CalendarMonthMath.weekViewOffset(weekCount: page.model.snapshot.weeks.count), accuracy: 0.5)
            page.press("\u{1b}", keyCode: 53)
            XCTAssertEqual(page.offset, 0, accuracy: 0.5, "Escape restores the month")
            XCTAssertTrue(try XCTUnwrap(page.element("calendar-search-button")).accessibilityPerformPress?() ?? false)
            page.settle()
            page.click(at: CGPoint(x: 160, y: 80), count: 1)
            XCTAssertEqual(page.offset, 0, accuracy: 0.5, "empty space restores the month")
        }
    }

    // MARK: - Every day's tile

    func testEmptyDaysKeepTheirOwnTileAndATileSelectsItsDay() throws {
        // 30 Oct onward are empty: each keeps its own tile, nothing folds.
        try withPage(events: [event("s", on: 29)]) { page in
            XCTAssertTrue(page.ids("calendar-free-").isEmpty, "no free-days line")
            let tiles = page.tiles()
            XCTAssertTrue(["2026-10-29", "2026-10-30", "2026-10-31"].allSatisfy(tiles.contains),
                          "today and the empty days after it, one tile each: \(tiles)")
            let tile = try XCTUnwrap(page.element("calendar-tile-2026-10-31"), "an empty day's tile")
            XCTAssertTrue(tile.accessibilityPerformPress?() ?? false, "the tile takes a click")
            page.settle()
            XCTAssertEqual(page.model.snapshot.selected, day(2026, 10, 31), "the click selects its day")
        }
    }

    func testPickingNextDayReusesUnchangedAgendaDayBody() throws {
        try withPage(events: []) { page in
            let retained = day(2026, 10, 30)
            let oldGroups = page.model.snapshot.groups
            let before = CalendarAgendaDay.bodyEvaluationsByDay[retained, default: 0]
            XCTAssertGreaterThan(before, 0, "the retained day was rendered before navigation")

            page.model.select(retained)
            page.settle()

            XCTAssertEqual(page.model.snapshot.groups.first, oldGroups[1],
                           "the next day and its content are unchanged after the selection")
            XCTAssertEqual(CalendarAgendaDay.bodyEvaluationsByDay[retained, default: 0], before,
                           "moving a day within the agenda must not rebuild its unchanged rows")
        }
    }

    /// Events loading while the page is scrolled: the days keep their tiles
    /// with unique ids, the selected day and the scroll position hold, and
    /// each load updates the page boundedly.
    func testEventsLoadingKeepTilesSelectionAndScroll() throws {
        let base = event("s", on: 29)
        try withPage(events: [base]) { page in
            page.scroll(to: 60)
            let offset = page.offset
            XCTAssertEqual(offset, 60, accuracy: 0.5, "scrolled into the month")
            let tiles = page.tiles()
            XCTAssertFalse(tiles.isEmpty)

            @MainActor func load(_ events: [CalendarEvent], _ message: String, line: UInt = #line) {
                let before = CalendarPage.bodyEvaluations
                page.source.replace(events)
                page.settle()
                XCTAssertEqual(page.tiles(), tiles, "\(message): the same day tiles", line: line)
                XCTAssertTrue(page.ids("calendar-free-").isEmpty, "\(message): nothing folds", line: line)
                XCTAssertEqual(page.model.snapshot.selected, day(2026, 10, 29), "\(message): the selection holds", line: line)
                XCTAssertEqual(page.offset, offset, accuracy: 0.5, "\(message): the scroll position holds", line: line)
                let updates = CalendarPage.bodyEvaluations - before
                XCTAssertLessThanOrEqual(updates, 3, "\(message): one load, a bounded number of updates", line: line)
                let quiet = CalendarPage.bodyEvaluations
                page.settle()
                XCTAssertEqual(CalendarPage.bodyEvaluations, quiet, "\(message): settles (no layout loop)", line: line)
            }

            let split = event("split", on: 1, month: 11)
            load([base, split], "an event on an empty day")
            let first = event("first", on: 30)
            load([base, split, first], "another")
            load([base, first], "an event going")
        }
    }

    // MARK: - Day view (Accepted 2026-11-09, Timeline)

    private func timed(_ id: String, _ d: Int, _ start: (Int, Int), _ end: (Int, Int), month m: Int = 10) -> CalendarEvent {
        CalendarEvent(id: id, title: "Event \(id)", start: date(2026, m, d, start.0, start.1), end: date(2026, m, d, end.0, end.1),
                      isAllDay: false, location: nil, calendarTitle: "Home",
                      colour: CalendarEventColour(red: 0.2, green: 0.5, blue: 0.9))
    }

    private func press(_ page: MountedPage, _ identifier: String, line: UInt = #line) throws {
        let element = try XCTUnwrap(page.element(identifier), identifier, line: line)
        XCTAssertTrue(element.accessibilityPerformPress?() ?? false, identifier, line: line)
        page.settle(0.5)
    }

    private func withReducedMotion(_ body: () throws -> Void) rethrows {
        AtticMotionPreference.systemReduceMotionOverride = true
        AtticTransparencySeam.systemOverride = true
        defer {
            AtticMotionPreference.systemReduceMotionOverride = nil
            AtticTransparencySeam.systemOverride = nil
        }
        try body()
    }

    func testDayViewReplacesTheGridWithTheHoursAndTheTitleReturnsToWeek() throws {
        try withReducedMotion {
            try withPage(events: [timed("a", 29, (14, 0), (15, 0))], height: 460) { page in
                XCTAssertNil(page.element("calendar-day-scroll"), "Month is the page's first view")
                page.model.setDayView(true)
                page.settle(0.5)
                XCTAssertNotNil(page.element("calendar-day-scroll"), "the hours")
                XCTAssertNotNil(page.element("calendar-event-a"), "the event, on the hours")
                XCTAssertTrue(page.tiles().isEmpty, "no agenda under the hours")
                XCTAssertNotNil(page.element("calendar-day-2026-10-26"), "the selected week stays on top")
                XCTAssertNil(page.element("calendar-day-2026-10-12"), "only that week")
                let weekRow = try XCTUnwrap(page.frame("calendar-day-2026-10-29"))
                let scroll = try XCTUnwrap(page.frame("calendar-day-scroll"))
                XCTAssertGreaterThanOrEqual(weekRow.minY, scroll.maxY - 0.5, "the week is above the hours")

                XCTAssertEqual(page.value("calendar-month-pill"), "Day")
                try press(page, "calendar-month-pill")
                XCTAssertFalse(page.model.isDayView, "the title goes back")
                XCTAssertNil(page.element("calendar-day-scroll"))
                // Accepted 2026-11-10: back to the picked view, Month here.
                XCTAssertEqual(page.offset, 0, accuracy: 0.5, "to the picked Month, at rest")
                XCTAssertEqual(page.value("calendar-month-pill"), "Month")
            }
        }
    }

    /// Leaving Day goes where it was asked, not to the offset the page last saved.
    func testReturningFromDayIsNotUndoneByTheResumeKeeper() throws {
        let suite = "CalendarDayResume-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        PanelResumeScrollKeeper.remember(0, key: "calendar", in: defaults)
        defaults.set(true, forKey: CalendarPageModel.weekPickedKey)
        try withReducedMotion {
            try withPage(events: [], height: 460, resumeDefaults: defaults) { page in
                page.model.setDayView(true)
                page.settle(0.5)
                try press(page, "calendar-month-pill")
                page.settle(0.5)
                XCTAssertEqual(page.offset, CalendarMonthMath.weekViewOffset(weekCount: 1), accuracy: 0.5)
            }
        }
    }

    // MARK: The picked view decides the fold (Accepted 2026-11-10)

    /// E-1: Month wins even while Week's animated scroll has started but
    /// its delayed replacement of the month grid has not run yet.
    func testE1MonthCancelsAnInFlightWeekFold() throws {
        AtticMotionPreference.systemReduceMotionOverride = false
        defer { AtticMotionPreference.systemReduceMotionOverride = nil }
        try withPage(events: [], height: 460) { page in
            page.model.pickWeek(true)
            page.settle(0.12)
            XCTAssertGreaterThan(page.offset, 2, "the Week scroll has begun")
            page.model.pickWeek(false)
            page.settle(0.8)
            XCTAssertFalse(page.model.isWeekPicked)
            XCTAssertEqual(page.offset, 0, accuracy: 0.5, "Month must unfold despite Week's unfinished task")
            XCTAssertTrue(page.ids("calendar-day-").contains("2026-10-12"), "all weeks are back")
        }
    }

    private static let selectedWeek = ["2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29",
                                       "2026-10-30", "2026-10-31", "2026-11-01"]

    /// Month, the default: the whole month at rest; scrolling the agenda up
    /// folds the grid to the selected week, and the top unfolds it again.
    func testMonthRestsUnfoldedScrollingFoldsAndTheTopUnfolds() throws {
        try withReducedMotion {
            try withPage(events: [], height: 460) { page in
                XCTAssertFalse(page.model.isWeekPicked, "Month is the default")
                XCTAssertEqual(page.offset, 0, accuracy: 0.5, "at rest, the whole month")
                XCTAssertEqual(page.value("calendar-month-pill"), "Month")
                XCTAssertTrue(page.ids("calendar-day-").contains("2026-10-12"), "every week of the month")
                let fold = CalendarMonthMath.weekViewOffset(weekCount: page.model.snapshot.weeks.count)
                page.scroll(to: fold + 40)
                XCTAssertEqual(page.value("calendar-month-pill"), "Week", "scrolled up: folded to the week")
                page.scroll(to: 0)
                XCTAssertEqual(page.value("calendar-month-pill"), "Month", "back at the top: unfolded")
                XCTAssertTrue(page.ids("calendar-day-").contains("2026-10-12"))
            }
        }
    }

    /// Week: the grid is the selected week's seven days at every offset,
    /// the top included, and after a search closes.
    func testWeekNeverUnfoldsOnAnyScrollOrAfterSearch() throws {
        try withReducedMotion {
            try withPage(events: [], height: 460) { page in
                page.model.pickWeek(true)
                page.settle(0.5)
                for y in [CGFloat(0), 120, 0, 2, 0] {
                    page.scroll(to: y)
                    XCTAssertEqual(page.value("calendar-month-pill"), "Week", "offset \(y)")
                    XCTAssertEqual(page.ids("calendar-day-"), Self.selectedWeek, "only the selected week at offset \(y)")
                }
                XCTAssertTrue(page.element("calendar-search-button")?.accessibilityPerformPress?() ?? false)
                page.settle()
                XCTAssertEqual(page.offset, CalendarMonthMath.weekViewOffset(weekCount: 1), accuracy: 0.5, "search folds to the week")
                XCTAssertTrue(page.element(label: "End search")?.accessibilityPerformPress?() ?? false)
                page.settle()
                page.scroll(to: 0)
                XCTAssertEqual(page.value("calendar-month-pill"), "Week", "search closed: still the week")
                XCTAssertEqual(page.ids("calendar-day-"), Self.selectedWeek)
                // ‹ › move a week; the title shows the month again.
                try press(page, "calendar-next")
                XCTAssertEqual(page.model.snapshot.selected, day(2026, 11, 5))
                XCTAssertEqual(page.ids("calendar-day-").count, 7)
                try press(page, "calendar-month-pill")
                XCTAssertFalse(page.model.isWeekPicked, "the title in Week shows the month")
                XCTAssertEqual(page.offset, 0, accuracy: 0.5)
                XCTAssertEqual(page.value("calendar-month-pill"), "Month")
            }
        }
    }

    /// Coming back from Day goes to the picked view, Week or Month.
    func testComingBackFromDayReturnsToThePickedView() throws {
        try withReducedMotion {
            try withPage(events: [], height: 460) { page in
                page.model.pickWeek(true)
                page.settle(0.5)
                page.model.setDayView(true)
                page.settle(0.5)
                try press(page, "calendar-month-pill")
                XCTAssertFalse(page.model.isDayView)
                XCTAssertEqual(page.value("calendar-month-pill"), "Week")
                XCTAssertEqual(page.ids("calendar-day-"), Self.selectedWeek)
                page.scroll(to: 0)
                XCTAssertEqual(page.ids("calendar-day-"), Self.selectedWeek, "and it stays the week")

                page.model.pickWeek(false)
                page.settle(0.5)
                page.model.setDayView(true)
                page.settle(0.5)
                try press(page, "calendar-month-pill")
                XCTAssertEqual(page.value("calendar-month-pill"), "Month")
                XCTAssertEqual(page.offset, 0, accuracy: 0.5)
                XCTAssertTrue(page.ids("calendar-day-").contains("2026-10-12"))
            }
        }
    }

    /// ••• ticks the picked view: Month stays ticked while a Month is folded
    /// by scrolling (that tick made Week look picked), Week while Week is.
    func testMoreTicksThePickedViewNotTheFold() throws {
        let chrome = PanelSharedChrome()
        func ticked() -> [String] {
            chrome.more(on: .calendar).filter { $0.state == .on }.map(\.title)
        }
        try withReducedMotion {
            try withPage(events: [], height: 460, chrome: chrome) { page in
                XCTAssertEqual(ticked(), ["Month"])
                page.scroll(to: CalendarMonthMath.weekViewOffset(weekCount: page.model.snapshot.weeks.count) + 40)
                XCTAssertEqual(page.value("calendar-month-pill"), "Week", "folded by scrolling")
                XCTAssertEqual(ticked(), ["Month"], "still Month: Week was not picked")
                page.model.pickWeek(true)
                page.settle(0.5)
                XCTAssertEqual(ticked(), ["Week"])
                page.scroll(to: 0)
                XCTAssertEqual(ticked(), ["Week"])
                page.model.pickWeek(false)
                page.settle(0.5)
                XCTAssertEqual(ticked(), ["Month"])
            }
        }
    }

    /// The picked view is kept across a relaunch.
    func testThePickedViewSurvivesARelaunch() throws {
        let suite = "CalendarPickedView-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try withReducedMotion {
            try withPage(events: [], height: 460, resumeDefaults: defaults) { page in
                page.model.pickWeek(true)
                page.settle(0.5)
            }
            try withPage(events: [], height: 460, resumeDefaults: defaults) { page in
                XCTAssertTrue(page.model.isWeekPicked)
                XCTAssertEqual(page.value("calendar-month-pill"), "Week")
                XCTAssertEqual(page.ids("calendar-day-"), Self.selectedWeek)
                page.model.pickWeek(false)
                page.settle(0.5)
            }
            try withPage(events: [], height: 460, resumeDefaults: defaults) { page in
                XCTAssertFalse(page.model.isWeekPicked)
                XCTAssertEqual(page.value("calendar-month-pill"), "Month")
                XCTAssertTrue(page.ids("calendar-day-").contains("2026-10-12"))
            }
        }
    }

    func testDayArrowsMoveOneDayAcrossAMonthAndGoToTodayReturns() throws {
        try withReducedMotion {
            try withPage(events: [], height: 460) { page in
                page.model.setDayView(true)
                page.settle(0.5)
                XCTAssertNotNil(page.element(label: "Next day"))
                XCTAssertNotNil(page.element(label: "Previous day"))
                try press(page, "calendar-next")
                XCTAssertEqual(page.model.snapshot.selected, day(2026, 10, 30))
                try press(page, "calendar-next")
                try press(page, "calendar-next")
                XCTAssertEqual(page.model.snapshot.selected, day(2026, 11, 1), "over the month's end")
                XCTAssertTrue(page.model.isDayView)
                try press(page, "calendar-previous")
                XCTAssertEqual(page.model.snapshot.selected, day(2026, 10, 31))
                try press(page, "calendar-today")
                XCTAssertEqual(page.model.snapshot.selected, day(2026, 10, 29))
            }
        }
    }

    func testDayOpensAtNowOrJustBeforeTheFirstEvent() throws {
        let hour = CalendarDayDesign.hourHeight
        try withReducedMotion {
            try withPage(events: [timed("a", 30, (9, 0), (10, 0)), timed("late", 1, (23, 0), (23, 30), month: 11)], height: 460) { page in
                page.model.setDayView(true)
                page.settle(0.5)
                XCTAssertEqual(page.hoursOffset, 11 * hour, accuracy: 0.5, "today: an hour before noon")
                page.model.shiftDay(by: 1)
                page.settle(0.5)
                XCTAssertEqual(page.hoursOffset, 8.5 * hour, accuracy: 0.5, "another day: half an hour before its first event")
                page.model.shiftDay(by: 1)
                page.settle(0.5)
                XCTAssertEqual(page.hoursOffset, 8 * hour, accuracy: 0.5, "an empty day: the morning")
                page.model.shiftDay(by: 1)
                page.settle(0.5)
                let scrollable = page.hoursOffset
                XCTAssertGreaterThan(scrollable, 15 * hour, "a late event: at the end of the day")
                XCTAssertLessThanOrEqual(scrollable, 24 * hour, "kept inside what scrolls")
            }
        }
    }

    func testAllDayEventsAndTasksSitBetweenTheWeekAndTheHours() throws {
        let id = UUID()
        let allDay = CalendarEvent(id: "all", title: "Holiday", start: date(2026, 10, 29), end: date(2026, 10, 30),
                                   isAllDay: true, location: nil, calendarTitle: "Home",
                                   colour: CalendarEventColour(red: 0.9, green: 0.4, blue: 0.2))
        try withReducedMotion {
            try withPage(events: [allDay, timed("t", 29, (13, 0), (14, 0))], seed: seedAgendaTask(id), height: 460) { page in
                page.model.setDayView(true)
                page.settle(0.5)
                let top = try XCTUnwrap(page.frame("calendar-day-top"), "the tasks and all-day events")
                let week = try XCTUnwrap(page.frame("calendar-day-2026-10-29"))
                let scroll = try XCTUnwrap(page.frame("calendar-day-scroll"))
                XCTAssertGreaterThanOrEqual(week.minY, top.maxY - 0.5, "under the week")
                XCTAssertGreaterThanOrEqual(top.minY, scroll.maxY - 0.5, "above the hours")
                let event = try XCTUnwrap(page.frame("calendar-event-all"))
                let task = try XCTUnwrap(page.frame("calendar-task-\(id.uuidString)"))
                XCTAssertTrue(top.insetBy(dx: -1, dy: -1).contains(CGPoint(x: event.midX, y: event.midY)), "the all-day event")
                XCTAssertGreaterThanOrEqual(event.minY, task.maxY - 0.5, "all-day first, then tasks")
                XCTAssertTrue(top.insetBy(dx: -1, dy: -1).contains(CGPoint(x: task.midX, y: task.midY)), "the task")
                XCTAssertNotNil(page.element("calendar-event-t"), "the timed event stays on the hours")
            }
        }
    }

    func testOverlappingEventsSitSideBySideOnThePage() throws {
        try withReducedMotion {
            try withPage(events: [timed("a", 30, (9, 0), (11, 0)), timed("b", 30, (9, 30), (10, 30))], height: 460) { page in
                page.model.select(day(2026, 10, 30))
                page.model.setDayView(true)
                page.settle(0.5)
                let a = try XCTUnwrap(page.frame("calendar-event-a"))
                let b = try XCTUnwrap(page.frame("calendar-event-b"))
                XCTAssertLessThanOrEqual(a.maxX, b.minX + 0.5, "side by side")
                XCTAssertEqual(a.width, b.width, accuracy: 1)
            }
        }
    }

    /// A click opens the event where it is; hours after it move down, and
    /// nothing is covered.
    func testClickingAnEventOpensItInPlaceAndLaterEventsMoveDown() throws {
        try withReducedMotion {
            try withPage(events: [timed("a", 30, (9, 0), (9, 30)), timed("b", 30, (9, 30), (10, 30))], height: 900) { page in
                page.model.select(day(2026, 10, 30))
                page.model.setDayView(true)
                page.settle(0.5)
                let closedB = try XCTUnwrap(page.frame("calendar-event-b"))
                try press(page, "calendar-event-a")
                XCTAssertEqual(page.model.eventRows.rowID, "a")
                XCTAssertEqual(page.model.eventRows.rowDay, day(2026, 10, 30))
                XCTAssertNotNil(page.element("calendar-event-duration-a"), "the read-only details, in place")
                XCTAssertNotNil(page.element("calendar-event-open-a"), "another calendar's event opens in Calendar")
                page.settle(0.5)
                let openA = try XCTUnwrap(page.frame("calendar-event-a"))
                let openB = try XCTUnwrap(page.frame("calendar-event-b"))
                XCTAssertLessThan(openB.maxY, closedB.maxY - 5, "the next event moved down")
                XCTAssertLessThanOrEqual(openB.maxY, openA.minY + 0.5, "and is not covered")
            }
        }
    }

    /// Selecting an event uses the page's edit path: the same writer, saved on close.
    func testEditingAnEventInDayViewSavesThroughTheWriterOnClose() throws {
        let backend = FakeCalendarEventWriteStore()
        backend.availableCalendars = [CalendarWriteCalendar(id: "test", title: "Test",
            colour: .init(red: 0.2, green: 0.5, blue: 0.9), sourceID: "fake", sourceTitle: "Fake", isWritable: true)]
        let undo = UndoRoute()
        let writer = EventKitCalendarEventWriter(store: backend, record: try CalendarOwnershipRecord(),
            undoRoute: undo, notificationCenter: NotificationCenter())
        let start = date(2026, 10, 30, 9)
        let owned = try writer.create(CalendarEventDraft(title: "Original", start: start, length: 3600,
                                                         calendarID: "test", timeZoneID: "Europe/London"))
        let event = CalendarEvent(id: owned.occurrenceID, title: "Original", start: start, end: start.addingTimeInterval(3600),
                                  isAllDay: false, location: nil, calendarTitle: "Test",
                                  colour: .init(red: 0.2, green: 0.5, blue: 0.9))
        try withReducedMotion {
            try withPage(events: [event], height: 900, makeWriter: { writer }) { page in
                page.model.select(day(2026, 10, 30))
                page.model.setDayView(true)
                page.settle(0.5)
                try press(page, "calendar-event-\(event.id)")
                page.settle(0.5)
                XCTAssertTrue(page.model.eventRows.canEdit, "Attic's own event edits in place")
                XCTAssertNotNil(page.element("calendar-event-title-\(event.id)"))
                page.model.eventRows.title = "Renamed"
                page.settle(0.2)
                try press(page, "calendar-next")
                XCTAssertEqual(backend.events.values.first?.draft.title, "Renamed", "moving day saves the edit, as the page does")
                XCTAssertEqual(page.model.snapshot.selected, day(2026, 10, 31))
            }
        }
    }

    func testDayTimelineIsBuiltLazilyAndScrollingWithinAnHourDoesNotRebuildIt() throws {
        try withReducedMotion {
            try withPage(events: [timed("a", 30, (9, 0), (10, 0))], height: 460) { page in
                page.model.select(day(2026, 10, 30))
                page.model.setDayView(true)
                page.settle(0.6)
                XCTAssertLessThan(CalendarDayView.builtHours, 25, "only the hours near the view")
                XCTAssertGreaterThan(CalendarDayView.builtHours, 6, "and enough to fill it")
                let start = page.hoursOffset
                let builds = CalendarDayView.timelineBuilds
                let scroller = try XCTUnwrap(page.scroller)
                scroller.contentView.scroll(to: NSPoint(x: 0, y: start + 4))
                scroller.reflectScrolledClipView(scroller.contentView)
                page.settle(0.3)
                XCTAssertEqual(CalendarDayView.timelineBuilds, builds, "a scroll inside the hour changes nothing")
                let quiet = CalendarDayView.timelineBuilds
                page.settle(0.4)
                XCTAssertEqual(CalendarDayView.timelineBuilds, quiet, "settles (no layout loop)")
            }
        }
    }

    func testDayLineTicksOnlyForTodayAndOnlyOnScreen() {
        let today = day(2026, 10, 29)
        XCTAssertTrue(CalendarDayView.ticks(day: today, today: today, isLive: true))
        XCTAssertFalse(CalendarDayView.ticks(day: today, today: today, isLive: false), "a hidden panel does no clock work")
        XCTAssertFalse(CalendarDayView.ticks(day: day(2026, 10, 30), today: today, isLive: true), "no line on another day")
    }

    // MARK: - Folding (item 14, owner rec2 2026-10-31)

    /// While the agenda scrolls the grid away, every frame draws the selected
    /// week once: at its place until it reaches the weekday letters, then
    /// held under them. Each offset is captured straight after the scroll
    /// (before any deferred state update) and again settled, and the scroll
    /// jumps back down past the pin as a fast flick does.
    func testTheSelectedWeekIsDrawnOnceAtEveryScrollOffset() throws {
        try withPage(events: []) { page in
            let top = try XCTUnwrap(page.scrollerTop)
            for y in [0, 60, 120, 136, 140, 142, 160, 200, 60, 150, 20, 175, 100, 0] as [CGFloat] {
                page.jump(to: y)
                try assertOneSelectedWeek(page, offset: y, viewportTop: top, "straight after a scroll to \(y)")
                page.settle(0.05)
                try assertOneSelectedWeek(page, offset: page.offset, viewportTop: top, "settled at \(y)")
            }
        }
    }

    /// The fold itself (the month title): every frame of the animation draws
    /// the selected week once, both ways.
    func testTheFoldAnimationDrawsTheSelectedWeekOnceInEveryFrame() throws {
        try withPage(events: []) { page in
            let top = try XCTUnwrap(page.scrollerTop)
            for direction in ["folding", "unfolding"] {
                let pill = try XCTUnwrap(page.element("calendar-month-pill"), "the month title")
                XCTAssertTrue(pill.accessibilityPerformPress?() ?? false, "\(direction): pressed")
                var frames = 0
                let end = Date().addingTimeInterval(0.8)
                while Date() < end {
                    RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 120))
                    page.window.displayIfNeeded()
                    try assertOneSelectedWeek(page, offset: page.offset, viewportTop: top, "\(direction) frame \(frames)")
                    frames += 1
                }
                XCTAssertGreaterThan(frames, 5, "\(direction): frames sampled")
                page.settle()
            }
            XCTAssertEqual(page.offset, 0, accuracy: 0.5, "unfolded back to the month")
        }
    }

    /// Nothing scrolls up under the weekday letters: the grid is cut at the
    /// top of its scroller, so the letters' band looks the same at any
    /// offset.
    func testNothingShowsUnderTheWeekdayLetters() throws {
        try withPage(events: []) { page in
            let top = try XCTUnwrap(page.scrollerTop)
            let band = (top - CalendarDesign.weekdayRowHeight - 2)..<(top - 0.5)
            let rest = try page.capture()
            for y in [20, 60, 100, 136, 142, 200] as [CGFloat] {
                page.jump(to: y)
                let scrolled = try page.capture()
                page.settle(0.05)
                let settled = try page.capture()
                for (name, image) in [("straight after", scrolled), ("settled", settled)] {
                    let diff = try Self.maxDifference(rest, image, band: band)
                    XCTAssertLessThan(diff, 0.02, "\(name) a scroll to \(y): the letters' band is unchanged (\(diff))")
                }
            }
        }
    }

    /// The selected day (today, so its key is the red one) in its column,
    /// left of the number: one red run of a key's height, where the week sits.
    private func assertOneSelectedWeek(_ page: MountedPage, offset: CGFloat, viewportTop: CGFloat,
                                       _ message: String, line: UInt = #line) throws {
        let image = try page.capture()
        let width = page.host.bounds.width
        let key = (width - 2 * CalendarDesign.gridInset - 6 * CalendarDesign.keyGap) / 7
        let x = CalendarDesign.gridInset + 3 * (key + CalendarDesign.keyGap) + key / 2 - 12
        let scale = CGFloat(image.pixelsHigh) / page.host.bounds.height
        let from = Int((viewportTop - CalendarDesign.weekdayRowHeight - 10) * scale)
        // Down to the grid's end (the agenda's red today tile lies below).
        let gridEnd = max(CalendarDesign.weekPitch, 5 * CalendarDesign.weekPitch - offset)
        let to = Int((viewportTop + gridEnd + 2) * scale)
        var runs: [(start: CGFloat, length: CGFloat)] = []
        var start: Int?
        for py in from...to {
            let c = try XCTUnwrap(image.colorAt(x: Int(x * scale), y: py)?.usingColorSpace(.sRGB))
            let red = c.redComponent - (c.greenComponent + c.blueComponent) / 2 > 0.25 && c.alphaComponent > 0.5
            if red, start == nil { start = py }
            if !red || py == to, let s = start {
                runs.append((CGFloat(s) / scale, CGFloat(py - s) / scale)); start = nil
            }
        }
        let keys = runs.filter { $0.length >= 8 }
        XCTAssertEqual(keys.count, 1, "\(message): one selected week drawn, runs \(runs)", line: line)
        let expected = viewportTop + max(0, 4 * CalendarDesign.weekPitch - offset) + CalendarDesign.weekTop
        if let first = keys.first {
            XCTAssertEqual(first.start, expected, accuracy: 2, "\(message): where the week sits", line: line)
            XCTAssertGreaterThan(first.length, CalendarDesign.keyHeight * 0.7, "\(message): the whole key", line: line)
        }
    }

    private static func maxDifference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, band: Range<CGFloat>) throws -> CGFloat {
        let scale = CGFloat(a.pixelsHigh) / a.size.height
        var worst: CGFloat = 0
        for py in Int(band.lowerBound * scale)..<Int(band.upperBound * scale) {
            for px in stride(from: 0, to: a.pixelsWide, by: 2) {
                let p = try XCTUnwrap(a.colorAt(x: px, y: py)?.usingColorSpace(.sRGB))
                let q = try XCTUnwrap(b.colorAt(x: px, y: py)?.usingColorSpace(.sRGB))
                worst = max(worst, abs(p.redComponent - q.redComponent), abs(p.greenComponent - q.greenComponent),
                            abs(p.blueComponent - q.blueComponent), abs(p.alphaComponent - q.alphaComponent))
            }
        }
        return worst
    }

    // MARK: - Agenda task rows (w2-tasks review 4)

    private func seedAgendaTask(_ id: UUID) -> (TaskStore) throws -> Void {
        { store in
            let context = ModelContext(store.container)
            let task = TaskItem(id: id, title: "Agenda task", createdAt: self.date(2026, 10, 1))
            task.listOrderVersion = TaskItem.currentListOrderVersion
            task.dueDay = self.day(2026, 10, 29)
            context.insert(task)
            try context.save()
            store.refresh()
        }
    }

    private func agendaActions(opened: @escaping (UUID) -> Void) -> (TaskStore) -> CalendarTaskRowActions {
        { store in
            CalendarTaskRowActions(toggleDone: { _ in }, open: opened, rename: { id, title in
                guard let task = store.task(withID: id) else { return false }
                return store.rename(task, to: title)
            })
        }
    }

    /// The mounted row's frame in window coordinates and its title's point.
    private func agendaRow(_ page: MountedPage, _ id: UUID) throws -> (element: AnyObject, title: CGPoint) {
        let row = try XCTUnwrap(page.element("calendar-task-\(id.uuidString)"), "the task's row in the agenda")
        let screen = try XCTUnwrap((row as? NSAccessibilityElementProtocol)?.accessibilityFrame())
        let frame = page.window.convertFromScreen(screen)
        return (row, CGPoint(x: frame.minX + TasksDesignMetrics.textX + 8, y: frame.maxY - TasksRowDesign.paddingY - TasksRowDesign.line / 2))
    }

    /// Runs one of the mounted row's own commands (VoiceOver's actions: the
    /// same closures its keys run).
    private func perform(_ name: String, on element: AnyObject, line: UInt = #line) {
        let actions = (element as? NSObject)?.value(forKey: "accessibilityCustomActions") as? [NSAccessibilityCustomAction] ?? []
        guard let action = actions.first(where: { $0.name == name }) else {
            return XCTFail("no \(name) in \(actions.map(\.name))", line: line)
        }
        if let handler = action.handler { _ = handler() } else if let target = action.target as? NSObject {
            _ = target.perform(action.selector, with: action)
        }
    }

    /// The agenda's task rows behave as the Tasks rows do, in the mounted
    /// page: a real click on the title selects, Return's command and a real
    /// double-click rename the task, Open page opens it.
    func testAgendaTaskRowsSelectOnAClickRenameAndOpenInTheMountedPage() throws {
        let id = UUID()
        var opened: [UUID] = []
        let makeActions = agendaActions { opened.append($0) }
        try withPage(events: [], seed: seedAgendaTask(id), taskActions: makeActions) { page in
            let rows = page.model.taskRows
            var (row, title) = try agendaRow(page, id)
            page.click(at: title, count: 1)
            XCTAssertEqual(rows.selected, id, "a real click on the title selects")
            XCTAssertEqual(opened, [], "and opens nothing")
            XCTAssertNil(rows.renaming)
            (row, title) = try agendaRow(page, id)
            perform("Edit title", on: row)
            page.settle()
            XCTAssertEqual(rows.renaming, id, "Return's command renames the selected task")
            XCTAssertEqual(rows.draft, "Agenda task")
            // The field's Return saves: the row's own editing commit.
            rows.draft = "Renamed in Calendar"
            let task = try XCTUnwrap(page.model.snapshot.groups.flatMap(\.items).compactMap { item -> CalendarTaskEntry? in
                if case let .task(task) = item, task.id == id { task } else { nil }
            }.first)
            let group = try XCTUnwrap(page.model.snapshot.groups.first { $0.day == self.day(2026, 10, 29) })
            let editing = try XCTUnwrap(CalendarAgendaDay(group: group, today: group.day, taskActions: makeActions(page.model.store),
                                                          rows: rows, onSelectDay: { _ in }).taskRow(task).titleEditing)
            XCTAssertTrue(editing.commit())
            page.settle()
            XCTAssertNil(rows.renaming, "saved")
            XCTAssertEqual(page.model.store.task(withID: id)?.title, "Renamed in Calendar")
            XCTAssertEqual(rows.selected, id, "still selected")
            (row, title) = try agendaRow(page, id)
            perform("Open page", on: row)
            XCTAssertEqual(opened, [id], "⇧⌘I's command opens its page")
            page.click(at: title, count: 1)
            page.click(at: title, count: 2)
            page.settle()
            XCTAssertEqual(rows.renaming, id, "a real double-click edits the title (owner, 2026-10-31)")
            XCTAssertEqual(opened, [id], "and opens nothing")
        }
    }

    /// The same with real keys (needs a key window and the desktop).
    func testAgendaTaskRowsAnswerRealReturnAndShiftCommandI() throws {
        try requireKeyWindowTests()
        let id = UUID()
        var opened: [UUID] = []
        let makeActions = agendaActions { opened.append($0) }
        try withPage(events: [], seed: seedAgendaTask(id), taskActions: makeActions, keyWindow: true) { page in
            let rows = page.model.taskRows
            page.click(at: try agendaRow(page, id).title, count: 1)
            XCTAssertEqual(rows.selected, id)
            page.press("\r", keyCode: 36)
            XCTAssertEqual(rows.renaming, id, "Return renames")
            page.press("\u{1b}", keyCode: 53)
            XCTAssertNil(rows.renaming, "Esc cancels")
            page.press("i", keyCode: 34, modifiers: [.command, .shift])
            XCTAssertEqual(opened, [id], "⇧⌘I opens")
        }
    }

    // MARK: - Calendar hunt: generated actions against a mounted page

    func testCalendarHuntSeededHostedNavigationKeepsThePickedGrid() throws {
        AtticMotionPreference.systemReduceMotionOverride = true
        defer { AtticMotionPreference.systemReduceMotionOverride = nil }
        var spanning = event("spanning", on: 28)
        spanning.start = date(2026, 10, 28, 23)
        spanning.end = date(2026, 10, 30, 2)
        let occurrences = [event("overlap-1", on: 29), event("overlap-2", on: 29, hour: 9),
                           event("repeat-0", on: 25), event("repeat-1", on: 1, month: 11), spanning]
        let picks = [day(2026, 10, 29), day(2026, 10, 31), day(2026, 11, 1),
                     day(2026, 3, 29), day(2027, 8, 31)]

        for seed in [UInt64(0xCAA1_1201), UInt64(0xCAA1_1202)] {
            var state = seed
            func next(_ upper: Int) -> Int {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Int((state >> 33) % UInt64(upper))
            }
            try withPage(events: occurrences, height: 460) { page in
                for step in 0..<300 {
                    let action = next(11)
                    switch action {
                    case 0: page.model.pickWeek(!page.model.isWeekPicked)
                    case 1: page.model.setDayView(!page.model.isDayView)
                    case 2: page.model.select(picks[next(picks.count)])
                    case 3: page.model.shift(by: next(2) == 0 ? -1 : 1, weekView: page.model.isWeekPicked)
                    case 4: page.model.shiftDay(by: next(2) == 0 ? -1 : 1)
                    case 5: page.model.goToToday()
                    case 6:
                        if let nextButton = page.element("calendar-next") {
                            XCTAssertTrue(nextButton.accessibilityPerformPress?() ?? false)
                        }
                    case 7:
                        if !page.model.isDayView, let title = page.element("calendar-month-pill") {
                            XCTAssertTrue(title.accessibilityPerformPress?() ?? false)
                        }
                    case 8:
                        page.model.setQuery(next(3) == 0 ? "spanning" : "")
                        page.model.commitSearch()
                    case 9: page.source.replace(next(2) == 0 ? occurrences : Array(occurrences.suffix(3)))
                    default:
                        if !page.model.isDayView { page.jump(to: [CGFloat(0), 65, 175, 0][next(4)]) }
                    }
                    // Wait for the first settled render: SwiftUI can display
                    // the previous month during a legal navigation transition.
                    page.settle(0.15)
                    let label = "seed=\(seed) step=\(step) action=\(action)"
                    let snapshot = page.model.snapshot
                    XCTAssertEqual(snapshot.month, CalendarMonth(snapshot.selected), label)
                    XCTAssertNotNil(snapshot.pinnedWeekIndex, label)
                    XCTAssertEqual(snapshot.weeks.flatMap(\.days).filter(\.isSelected).count, 1, label)
                    if page.model.isDayView && !snapshot.isSearching {
                        XCTAssertNotNil(page.element("calendar-day"), label)
                    } else if page.model.isWeekPicked {
                        let drawn = page.ids("calendar-day-")
                        let expected = snapshot.weeks[snapshot.pinnedWeekIndex!].days.map { $0.day.description }
                        XCTAssertEqual(drawn, expected, label)
                        XCTAssertEqual(page.value("calendar-month-pill"), "Week", label)
                    } else if page.offset <= 0.5 {
                        XCTAssertTrue(page.ids("calendar-day-").contains(snapshot.selected.description),
                                      "\(label), pickedWeek=\(page.model.isWeekPicked), dayView=\(page.model.isDayView), "
                                      + "scroll=\(page.offset), pill=\(page.value("calendar-month-pill") ?? "none"), "
                                      + "drawn=\(page.ids("calendar-day-")) selected=\(snapshot.selected)")
                    }
                }
                print("CALENDAR_HUNT_HOSTED seed=\(seed) steps=300")
            }
        }
    }

    func testCalendarHuntHideAndRevealDuringAnAnimatedFoldSettlesThePickedView() throws {
        AtticMotionPreference.systemReduceMotionOverride = false
        defer { AtticMotionPreference.systemReduceMotionOverride = nil }
        let source = CalendarEventSourceStub(events: [event("one", on: 29)])
        let model = CalendarPageModel(store: try makeTestStore(), source: source,
                                      calendar: calendar, now: { self.date(2026, 10, 29, 12) })
        let visible = CalendarVisibilityProbe()
        let size = CGSize(width: 320, height: 460)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(CalendarVisibilityProbeView(probe: visible, model: model)))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let page = MountedPage(model: model, source: source, host: host, window: window)
        visible.onScreen = true
        page.settle(0.2)

        for cycle in 0..<4 {
            model.pickWeek(true)
            page.settle(0.06)
            visible.onScreen = false
            page.settle(0.02)
            // While hidden, the owner may pick Month and reveal the panel.
            model.pickWeek(false)
            visible.onScreen = true
            page.settle(0.8)
            XCTAssertFalse(model.isWeekPicked, "cycle \(cycle)")
            XCTAssertEqual(page.offset, 0, accuracy: 0.5, "cycle \(cycle): no unfinished fold")
            XCTAssertTrue(page.ids("calendar-day-").contains("2026-10-12"),
                          "cycle \(cycle): month restored; drawn=\(page.ids("calendar-day-")), "
                          + "pill=\(page.value("calendar-month-pill") ?? "none")")
        }
    }

    /// Off-screen, first-frame candidates. Includes the source read and
    /// SwiftUI's first layout/display turn, with identical work at both sizes.
    func testCalendarHuntMonthWeekAndPagingFrameCandidatesAt10And300Events() throws {
        AtticMotionPreference.systemReduceMotionOverride = true
        defer { AtticMotionPreference.systemReduceMotionOverride = nil }
        func percentile(_ times: [Double], _ fraction: Double) -> Double {
            let ordered = times.sorted()
            return ordered[min(ordered.count - 1, Int(Double(ordered.count) * fraction))]
        }
        for count in [10, 300] {
            let occurrences: [CalendarEvent] = (0..<count).map { index in
                let start = calendar.date(byAdding: .minute, value: (index % 14) * 1440 + (index % 18) * 20,
                                          to: date(2026, 10, 29))!
                return CalendarEvent(id: "hunt-frame-\(index)", title: "Meeting \(index)", start: start,
                                     end: start.addingTimeInterval(45 * 60), isAllDay: false, location: nil,
                                     calendarTitle: "Fake", colour: CalendarEventColour(red: 0.2, green: 0.5, blue: 0.9))
            }
            try withPage(events: occurrences, height: 460) { page in
                var fold: [Double] = [], unfold: [Double] = [], paging: [Double] = []
                for repetition in 0..<9 {
                    // Allow an initial warm pass before recording eight samples.
                    @MainActor func frame(_ action: @MainActor () -> Void) -> Double {
                        let begin = ProcessInfo.processInfo.systemUptime
                        action()
                        page.settle(0.016)
                        return (ProcessInfo.processInfo.systemUptime - begin) * 1_000
                    }
                    let toWeek = frame { page.model.pickWeek(true) }
                    let toNextWeek = frame { page.model.shift(by: 1, weekView: true) }
                    _ = frame { page.model.shift(by: -1, weekView: true) }
                    let toMonth = frame { page.model.pickWeek(false) }
                    if repetition > 0 {
                        fold.append(toWeek)
                        paging.append(toNextWeek)
                        unfold.append(toMonth)
                    }
                }
                print(String(format: "CALENDAR_HUNT_FRAME events=%d samples=8 fold_p50=%.2fms fold_p95=%.2fms unfold_p50=%.2fms unfold_p95=%.2fms page_p50=%.2fms page_p95=%.2fms",
                             count, percentile(fold, 0.5), percentile(fold, 0.95),
                             percentile(unfold, 0.5), percentile(unfold, 0.95),
                             percentile(paging, 0.5), percentile(paging, 0.95)))
                XCTAssertFalse(page.model.isWeekPicked)
            }
        }
    }

    // MARK: - Mounting

    @MainActor private struct MountedPage {
        let model: CalendarPageModel
        let source: CalendarEventSourceStub
        let host: NSHostingView<AnyView>
        let window: NSWindow

        func settle(_ seconds: TimeInterval = 0.3) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        /// A real click (window coordinates), through the app's queue.
        func click(at point: CGPoint, count: Int) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, eventNumber: 9, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0)!
                NSApp.postEvent(event, atStart: false)
            }
            Hosted.pumpEvents()
            settle(0.3)
        }

        /// A real key press, through the app's queue.
        func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                             isARepeat: false, keyCode: keyCode)!
                NSApp.postEvent(event, atStart: false)
                Hosted.pumpEvents()
            }
            settle(0.4)
        }

        var scroller: NSScrollView? { Self.scrollView(in: host) }

        /// The Day view's hours: its tallest scroller.
        var hoursOffset: CGFloat {
            host.layoutSubtreeIfNeeded()
            let hours = Self.scrollViews(in: host).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
            return hours?.contentView.bounds.origin.y ?? -1
        }

        /// An element's frame in window coordinates (y grows upward).
        func frame(_ identifier: String) -> CGRect? {
            guard let element = self.element(identifier) as? NSAccessibilityElementProtocol else { return nil }
            return window.convertFromScreen(element.accessibilityFrame())
        }

        /// The top of the scroller (where the grid starts), in the host's
        /// flipped coordinates.
        var scrollerTop: CGFloat? {
            host.layoutSubtreeIfNeeded()
            guard let scroller else { return nil }
            return host.convert(scroller.bounds, from: scroller).minY
        }

        /// A scroll without letting the run loop turn: what the very next
        /// frame shows, before any deferred state update.
        func jump(to y: CGFloat) {
            guard let scroller else { return XCTFail("the page's scroller") }
            scroller.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroller.reflectScrolledClipView(scroller.contentView)
            host.layoutSubtreeIfNeeded()
        }

        func capture() throws -> NSBitmapImageRep {
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep
        }

        var offset: CGFloat { scroller?.contentView.bounds.origin.y ?? -1 }

        func scroll(to y: CGFloat) {
            guard let scroller else { return XCTFail("the page's scroller") }
            scroller.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroller.reflectScrolledClipView(scroller.contentView)
            settle()
        }

        func element(_ identifier: String) -> AnyObject? { matching(identifier).first }

        func value(_ identifier: String) -> String? {
            // SwiftUI's node answers the protocol's accessibilityValue().
            (element(identifier) as? NSObject)?.perform(Selector(("accessibilityValue")))?.takeUnretainedValue() as? String
        }

        func element(label: String) -> AnyObject? {
            host.layoutSubtreeIfNeeded()
            return Self.elements(host).first { ($0.accessibilityLabel?() ?? "") == label }
        }

        func matching(_ identifier: String) -> [AnyObject] {
            host.layoutSubtreeIfNeeded()
            return Self.elements(host).filter { ($0.accessibilityIdentifier?() ?? "") == identifier }
        }

        /// The dates (yyyy-MM-dd) of the drawn elements whose id starts with `prefix`.
        func ids(_ prefix: String) -> [String] {
            host.layoutSubtreeIfNeeded()
            let ids = Self.elements(host).compactMap { $0.accessibilityIdentifier?() }
                .filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
            var seen = Set<String>()
            return ids.filter { seen.insert($0).inserted }.sorted()
        }

        func tiles() -> [String] { ids("calendar-tile-") }

        private static func elements(_ root: AnyObject) -> [AnyObject] {
            let children = (root.accessibilityChildren?() ?? nil) ?? []
            return [root] + children.flatMap { elements($0 as AnyObject) }
        }

        private static func scrollViews(in view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
        }

        private static func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.documentView != nil { return scroll }
            for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
            return nil
        }
    }

    /// Today is 29 Oct 2026 at noon and selected. The window is tall enough
    /// that all seven agenda days are drawn.
    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private func withPage(events: [CalendarEvent], seed: (TaskStore) throws -> Void = { _ in },
                          taskActions: ((TaskStore) -> CalendarTaskRowActions)? = nil, keyWindow: Bool = false,
                          height: CGFloat = 900, makeWriter: (() throws -> CalendarEventWriter)? = nil,
                          resumeDefaults: UserDefaults? = nil, chrome: PanelSharedChrome? = nil,
                          _ body: (MountedPage) throws -> Void) throws {
        let store = try makeTestStore()
        try seed(store)
        let source = CalendarEventSourceStub(events: events)
        let model = CalendarPageModel(store: store, source: source, calendar: calendar, now: { self.date(2026, 10, 29, 12) },
                                      makeWriter: makeWriter, resumeDefaults: resumeDefaults)
        let size = CGSize(width: 320, height: height)
        let layout = PanelPageLayout(cornerSize: 28, panelSize: size)
        var design = AtticDesignContext(mode: .light)
        design.reduceMotion = AtticMotionPreference.systemReduceMotionOverride ?? false
        design.reduceTransparency = AtticTransparencySeam.systemOverride ?? false
        let page = CalendarPage(model: model, layout: layout,
                                taskActions: taskActions?(store) ?? CalendarTaskRowActions(toggleDone: { _ in }, open: { _ in }),
                                onNewTask: { _ in })
            .environment(\.panelResumeDefaults, resumeDefaults)
            .environment(\.panelSharedChrome, chrome)
            .atticDesign(design)
            .frame(width: size.width, height: size.height)
        let window: NSWindow = keyWindow
            ? KeyPanel(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            : NSWindow(contentRect: CGRect(origin: CGPoint(x: -4_000, y: -4_000), size: size),
                       styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(page))
        window.contentView = host
        window.orderFront(nil)
        if keyWindow { window.makeKey() }
        defer { window.orderOut(nil) }
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        let mounted = MountedPage(model: model, source: source, host: host, window: window)
        mounted.settle(0.6)
        try body(mounted)
    }
}
