import CoreGraphics
import XCTest
@testable import Attic

/// The Day view's timeline as values (Accepted 2026-11-09, Timeline): the
/// drawing's numbers, shared rows, the room an open event makes, and days
/// that are not 24 hours long.
final class CalendarDayLayoutTests: XCTestCase {
    private let london = CalendarMonthMath.calendar(timeZone: TimeZone(identifier: "Europe/London")!)
    private let hour = CalendarDayDesign.hourHeight
    private let top = CalendarDayDesign.topInset

    private func day(_ y: Int, _ m: Int, _ d: Int) -> DueDay { DueDay(year: y, month: m, day: d)! }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        london.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func event(_ id: String, _ start: Date, _ end: Date, allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: id, title: id, start: start, end: end, isAllDay: allDay, location: nil,
                      calendarTitle: "Home", colour: CalendarEventColour(red: 0.2, green: 0.5, blue: 0.9))
    }

    private func at(_ h: Int, _ m: Int = 0) -> Date { date(2026, 10, 30, h, m) }

    private func layout(_ events: [CalendarEvent], day d: DueDay? = nil, now: Date? = nil,
                        open: String? = nil, height: CGFloat = 0) -> CalendarDayLayout {
        let day = d ?? self.day(2026, 10, 30)
        return CalendarDayLayout(day: day, today: self.day(2026, 10, 29), now: now ?? date(2026, 10, 29, 12), events: events,
                                 calendar: london, openEventID: open, openContentHeight: height)
    }

    private func block(_ id: String, in layout: CalendarDayLayout) throws -> CalendarDayLayout.Block {
        try XCTUnwrap(layout.blocks.first { $0.id == id }, id)
    }

    // MARK: The drawing's numbers

    func testAnHourIs44PointsAndABlockStandsClearOfItsLines() throws {
        let day = layout([event("a", at(9), at(10))])
        XCTAssertEqual(day.hours.count, 25)
        XCTAssertEqual(day.hours[9].y, top + 9 * hour)
        XCTAssertEqual(day.height, top + 24 * hour + CalendarDayDesign.tail)
        let a = try block("a", in: day)
        XCTAssertEqual(a.y, top + 9 * hour + 0.5)
        XCTAssertEqual(a.height, hour - 1)
        let frame = day.frame(of: a, width: 300)
        XCTAssertEqual(frame.minX, 41)
        XCTAssertEqual(frame.width, 259)
    }

    func testABriefEventKeepsItsMinimumAndHidesItsSecondLine() throws {
        let day = layout([event("short", at(9), at(9, 15)), event("hour", at(11), at(12))])
        let short = try block("short", in: day)
        XCTAssertEqual(short.height, 21)
        XCTAssertFalse(short.showsMeta)
        XCTAssertEqual(short.paddingY, 3)
        let hourLong = try block("hour", in: day)
        XCTAssertTrue(hourLong.showsMeta)
        XCTAssertEqual(hourLong.paddingY, 4.5)
    }

    func testAllDayEventsAreNotOnTheHours() {
        XCTAssertTrue(layout([event("all", date(2026, 10, 30), date(2026, 10, 31), allDay: true)]).blocks.isEmpty)
    }

    // MARK: Overlap

    func testOverlappingEventsShareTheRowEqually() throws {
        let day = layout([event("a", at(9), at(10, 30)), event("b", at(9, 30), at(10, 30)), event("c", at(11), at(12))])
        let a = try block("a", in: day), b = try block("b", in: day), c = try block("c", in: day)
        XCTAssertEqual([a.lane, a.laneCount], [0, 2])
        XCTAssertEqual([b.lane, b.laneCount], [1, 2])
        XCTAssertEqual([c.lane, c.laneCount], [0, 1], "after the overlap, the whole width")
        let fa = day.frame(of: a, width: 300), fb = day.frame(of: b, width: 300)
        XCTAssertEqual(fa.minX, 41)
        XCTAssertEqual(fa.width, 259 / 2 - 2, accuracy: 0.01)
        XCTAssertEqual(fb.minX, 41 + 259 / 2, accuracy: 0.01)
        XCTAssertLessThanOrEqual(fa.maxX, fb.minX)
    }

    func testAChainOfOverlapsReusesAFreedRow() throws {
        let day = layout([event("a", at(9), at(11)), event("b", at(10), at(12)), event("c", at(11), at(13))])
        XCTAssertEqual(try block("c", in: day).lane, 0, "a's row is free by then")
        XCTAssertEqual(day.blocks.map(\.laneCount), [2, 2, 2])
    }

    func testBackToBackEventsDoNotShareARow() {
        XCTAssertEqual(layout([event("a", at(9), at(10)), event("b", at(10), at(11))]).blocks.map(\.laneCount), [1, 1])
    }

    /// Two 15-minute events in a row take more room than their time; side by
    /// side, so the first's minimum height does not cover the second.
    func testBriefBackToBackEventsSitSideBySideRatherThanCover() {
        XCTAssertEqual(layout([event("a", at(9), at(9, 15)), event("b", at(9, 15), at(9, 30))]).blocks.map(\.lane), [0, 1])
    }

    // MARK: Making room

    func testAnOpenEventPushesLaterHoursAndEventsDown() throws {
        let events = [event("a", at(9), at(9, 30)), event("b", at(10), at(11))]
        let closed = layout(events)
        let open = layout(events, open: "a", height: 80)
        XCTAssertEqual(open.room, 80 + 1 - 22)
        XCTAssertEqual(open.hours[9].y, closed.hours[9].y, "hours before it stay")
        XCTAssertEqual(open.hours[10].y, closed.hours[10].y + open.room, "later hours move")
        XCTAssertEqual(try block("b", in: open).y, try block("b", in: closed).y + open.room)
        XCTAssertEqual(try block("a", in: open).height, 80)
        XCTAssertTrue(try block("a", in: open).showsMeta)
        XCTAssertEqual(open.height, closed.height + open.room)
    }

    func testAnEventThatFitsMakesNoRoom() {
        XCTAssertEqual(layout([event("a", at(9), at(12))], open: "a", height: 60).room, 0)
    }

    func testASideBySideEventStillEndsOnItsMovedHour() throws {
        let events = [event("a", at(9), at(10)), event("b", at(9, 30), at(11))]
        let open = layout(events, open: "a", height: 90)
        let b = try block("b", in: open)
        XCTAssertEqual(b.y + b.height + 0.5, open.hours[11].y, accuracy: 0.01)
    }

    // MARK: Day boundaries

    func testASpringChangeDayIs23HoursLongAndSkipsTheHour() throws {
        let d = day(2026, 3, 29)
        let day = layout([event("a", date(2026, 3, 29, 3), date(2026, 3, 29, 4))], day: d)
        XCTAssertEqual(day.hours.count, 24, "23 hours and the closing line")
        XCTAssertEqual(london.component(.hour, from: day.hours[1].date), 2, "01:00 does not exist")
        XCTAssertEqual(try block("a", in: day).y, top + 2 * hour + 0.5, "03:00 is two hours in")
        XCTAssertEqual(day.height, top + 23 * hour + CalendarDayDesign.tail)
    }

    func testAnAutumnChangeDayIs25HoursLongAndKeepsBothOneThirties() throws {
        let d = day(2026, 10, 25)
        let start = date(2026, 10, 25)
        let first = event("first", start.addingTimeInterval(1.5 * 3600), start.addingTimeInterval(2 * 3600))
        let second = event("second", start.addingTimeInterval(2.5 * 3600), start.addingTimeInterval(3 * 3600))
        let day = layout([first, second], day: d)
        XCTAssertEqual(day.hours.count, 26)
        XCTAssertEqual([1, 2].map { london.component(.hour, from: day.hours[$0].date) }, [1, 1], "the hour repeats")
        XCTAssertEqual(try block("second", in: day).y - block("first", in: day).y, hour, "an hour apart, not on top of each other")
        XCTAssertEqual(day.blocks.map(\.laneCount), [1, 1])
    }

    func testAnEventCrossingMidnightIsClippedToEachDay() throws {
        let night = event("night", date(2026, 10, 30, 23), date(2026, 10, 31, 1))
        let before = layout([night], day: day(2026, 10, 30))
        let after = layout([night], day: day(2026, 10, 31))
        XCTAssertEqual(try block("night", in: before).y, top + 23 * hour + 0.5)
        XCTAssertEqual(try block("night", in: before).height, hour - 1, "up to midnight")
        XCTAssertEqual(try block("night", in: after).y, top + 0.5, "from midnight")
        XCTAssertEqual(try block("night", in: after).height, hour - 1)
        XCTAssertEqual(try block("night", in: after).event.start, night.start, "the event itself keeps its real times")
    }

    func testAnEventEndingAtMidnightIsNotOnTheNextDay() {
        let late = event("late", date(2026, 10, 30, 23), date(2026, 10, 31))
        XCTAssertTrue(CalendarAgenda.events(on: day(2026, 10, 31), in: [late], calendar: london).isEmpty)
        XCTAssertEqual(CalendarAgenda.events(on: day(2026, 10, 30), in: [late], calendar: london).map(\.id), ["late"])
    }

    // MARK: Now

    func testTheNowLineIsOnTodayOnlyAndTakesTheNearbyHoursLabel() {
        let today = day(2026, 10, 29)
        let noonish = date(2026, 10, 29, 12, 10)
        let day = layout([], day: today, now: noonish)
        XCTAssertEqual(day.nowY, top + (12 + 10.0 / 60) * hour)
        XCTAssertEqual(day.hours.filter(\.isLabelHidden).map(\.index), [12])
        XCTAssertNil(layout([], day: self.day(2026, 10, 30), now: noonish).nowY)
    }

    func testAnEventIsOverOnceItHasEnded() throws {
        let today = day(2026, 10, 29)
        let events = [event("done", date(2026, 10, 29, 9), date(2026, 10, 29, 10)),
                      event("later", date(2026, 10, 29, 14), date(2026, 10, 29, 15))]
        let day = layout(events, day: today, now: date(2026, 10, 29, 12))
        XCTAssertTrue(try block("done", in: day).isOver)
        XCTAssertFalse(try block("later", in: day).isOver)
        XCTAssertTrue(try block("x", in: layout([event("x", date(2026, 10, 28, 9), date(2026, 10, 28, 10))], day: self.day(2026, 10, 28))).isOver)
    }

    // MARK: Opening position

    private func opening(_ d: DueDay, now: Date, _ events: [CalendarEvent] = []) -> CGFloat {
        CalendarDayLayout.openingOffset(day: d, today: day(2026, 10, 29), now: now, events: events, calendar: london)
    }

    func testTodayOpensAnHourBeforeNow() {
        XCTAssertEqual(opening(day(2026, 10, 29), now: date(2026, 10, 29, 12)), 11 * hour)
    }

    func testTodayJustAfterMidnightOpensAtTheTop() {
        XCTAssertEqual(opening(day(2026, 10, 29), now: date(2026, 10, 29, 0, 20)), 0)
    }

    func testAnotherDayOpensHalfAnHourBeforeItsFirstEvent() {
        let events = [event("b", at(14), at(15)), event("a", at(9), at(10))]
        XCTAssertEqual(opening(day(2026, 10, 30), now: date(2026, 10, 29, 12), events), 8.5 * hour)
    }

    func testAnEmptyDayOpensAtEightInTheMorning() {
        XCTAssertEqual(opening(day(2026, 10, 30), now: date(2026, 10, 29, 12)), 8 * hour)
    }

    func testEightOClockOnASpringChangeDayIsSevenHoursIn() {
        XCTAssertEqual(opening(day(2026, 3, 29), now: date(2026, 10, 29, 12)), 7 * hour)
    }

    func testAnEventFromTheNightBeforeOpensTheDayAtTheTop() {
        let night = event("night", date(2026, 10, 29, 23), date(2026, 10, 30, 1))
        XCTAssertEqual(opening(day(2026, 10, 30), now: date(2026, 10, 29, 12), [night]), 0)
    }

    func testAllDayEventsDoNotDecideTheOpeningPosition() {
        let all = event("all", date(2026, 10, 30), date(2026, 10, 31), allDay: true)
        XCTAssertEqual(opening(day(2026, 10, 30), now: date(2026, 10, 29, 12), [all]), 8 * hour)
    }

    func testTheOpeningPositionStaysInsideWhatScrolls() {
        XCTAssertEqual(CalendarDayLayout.clampedOffset(900, contentHeight: 1000, viewport: 300), 700)
        XCTAssertEqual(CalendarDayLayout.clampedOffset(900, contentHeight: 200, viewport: 300), 0)
    }
}

final class CalendarDayNavigationTests: XCTestCase {
    func testADayStepCrossesMonthYearAndClockChanges() {
        let london = CalendarMonthMath.calendar(timeZone: TimeZone(identifier: "Europe/London")!)
        func step(_ a: (Int, Int, Int), _ n: Int) -> DueDay {
            CalendarMonthMath.adding(days: n, to: DueDay(year: a.0, month: a.1, day: a.2)!, calendar: london)
        }
        XCTAssertEqual(step((2026, 10, 31), 1), DueDay(year: 2026, month: 11, day: 1))
        XCTAssertEqual(step((2026, 12, 31), 1), DueDay(year: 2027, month: 1, day: 1))
        XCTAssertEqual(step((2026, 3, 28), 1), DueDay(year: 2026, month: 3, day: 29))
        XCTAssertEqual(step((2026, 3, 29), 1), DueDay(year: 2026, month: 3, day: 30), "a 23-hour day is still one day")
        XCTAssertEqual(step((2026, 10, 25), -1), DueDay(year: 2026, month: 10, day: 24), "and a 25-hour one")
    }
}
