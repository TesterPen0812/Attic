import CoreGraphics
import EventKit
import XCTest
@testable import Attic

/// A fake behind the `EKEventStore` seam: no real EventKit, no prompt.
private final class FakeCalendarEventStore: CalendarEventStoring {
    var status: EKAuthorizationStatus
    var statusAfterRequest: EKAuthorizationStatus
    var stored: [CalendarStoreOccurrence] = []
    private(set) var requestCount = 0
    private(set) var queries: [DateInterval] = []

    init(status: EKAuthorizationStatus = .fullAccess, statusAfterRequest: EKAuthorizationStatus = .fullAccess) {
        self.status = status
        self.statusAfterRequest = statusAfterRequest
    }

    func authorizationStatus() -> EKAuthorizationStatus { status }

    func requestFullAccess() async throws -> Bool {
        requestCount += 1
        status = statusAfterRequest
        return status == .fullAccess
    }

    func occurrences(from start: Date, to end: Date) -> [CalendarStoreOccurrence] {
        queries.append(DateInterval(start: start, end: end))
        // Like EventKit: anything touching the span, inclusive at both ends.
        return stored.filter { $0.start <= end && $0.end >= start }
    }
}

@MainActor
final class EventKitCalendarEventSourceTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> DateInterval {
        let start = date(year, month, day)
        return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
    }

    private func occurrence(
        _ id: String, _ title: String, _ start: Date, _ end: Date,
        allDay: Bool = false, location: String? = nil, colour: CGColor? = nil, timeZone: TimeZone? = nil
    ) -> CalendarStoreOccurrence {
        CalendarStoreOccurrence(
            eventIdentifier: id, itemIdentifier: "item-\(id)", title: title, start: start, end: end,
            isAllDay: allDay, location: location, calendarTitle: "Home", calendarColour: colour, timeZone: timeZone
        )
    }

    private func source(_ store: FakeCalendarEventStore, center: NotificationCenter = NotificationCenter()) -> EventKitCalendarEventSource {
        EventKitCalendarEventSource(store: store, calendar: calendar, notificationCenter: center)
    }

    // MARK: Access

    func testStatusMapping() {
        XCTAssertEqual(EventKitCalendarEventSource.accessState(for: .fullAccess), .granted)
        XCTAssertEqual(EventKitCalendarEventSource.accessState(for: .writeOnly), .denied)
        XCTAssertEqual(EventKitCalendarEventSource.accessState(for: .denied), .denied)
        XCTAssertEqual(EventKitCalendarEventSource.accessState(for: .restricted), .restricted)
        XCTAssertEqual(EventKitCalendarEventSource.accessState(for: .notDetermined), .notDetermined)
    }

    func testRequestAccessAsksOnlyWhenNotDetermined() async {
        let fresh = FakeCalendarEventStore(status: .notDetermined, statusAfterRequest: .fullAccess)
        let freshState = await source(fresh).requestAccess()
        XCTAssertEqual(freshState, .granted)
        XCTAssertEqual(fresh.requestCount, 1)

        let denied = FakeCalendarEventStore(status: .denied)
        let deniedState = await source(denied).requestAccess()
        XCTAssertEqual(deniedState, .denied)
        XCTAssertEqual(denied.requestCount, 0, "never prompts again after a denial")

        let writeOnly = FakeCalendarEventStore(status: .writeOnly)
        let writeOnlyState = await source(writeOnly).requestAccess()
        XCTAssertEqual(writeOnlyState, .denied)
        XCTAssertEqual(writeOnly.requestCount, 0)
    }

    func testNoEventsWithoutFullAccess() {
        for status: EKAuthorizationStatus in [.notDetermined, .denied, .restricted, .writeOnly] {
            let store = FakeCalendarEventStore(status: status)
            store.stored = [occurrence("a", "Lecture", date(2026, 10, 29, 9), date(2026, 10, 29, 10))]
            XCTAssertTrue(source(store).events(in: day(2026, 10, 29)).isEmpty)
            XCTAssertTrue(store.queries.isEmpty, "no store read without access")
        }
    }

    // MARK: Occurrences

    func testRepeatOccurrencesGetDistinctStableIDs() {
        let store = FakeCalendarEventStore()
        let mondays = (0..<3).map { week in
            occurrence("standup", "Standup", date(2026, 10, 5 + 7 * week, 9), date(2026, 10, 5 + 7 * week, 9, 15))
        }
        store.stored = mondays
        let source = source(store)
        let month = DateInterval(start: date(2026, 10, 1), end: date(2026, 11, 1))
        let events = source.events(in: month)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(Set(events.map(\.id)).count, 3)
        XCTAssertEqual(events.first?.id, EventKitCalendarEventSource.occurrenceID(eventIdentifier: "standup", start: mondays[0].start))
        XCTAssertEqual(source.events(in: month).map(\.id), events.map(\.id), "ids are stable across reads")
    }

    func testCollidingIDsAreMadeUnique() {
        let store = FakeCalendarEventStore()
        let start = date(2026, 10, 29, 9)
        store.stored = [
            occurrence("dup", "A", start, date(2026, 10, 29, 10)),
            occurrence("dup", "B", start, date(2026, 10, 29, 11)),
        ]
        let events = source(store).events(in: day(2026, 10, 29))
        XCTAssertEqual(events.map(\.title), ["A", "B"])
        XCTAssertEqual(Set(events.map(\.id)).count, 2)
    }

    func testEventsSortedByStartThenTitleAndMissingIDFallsBack() {
        let store = FakeCalendarEventStore()
        var noID = occurrence("x", "Zeta", date(2026, 10, 29, 8), date(2026, 10, 29, 9), location: "  ")
        noID.eventIdentifier = nil
        store.stored = [
            occurrence("b", "Beta", date(2026, 10, 29, 9), date(2026, 10, 29, 10)),
            occurrence("a", "Alpha", date(2026, 10, 29, 9), date(2026, 10, 29, 10)),
            noID,
        ]
        let events = source(store).events(in: day(2026, 10, 29))
        XCTAssertEqual(events.map(\.title), ["Zeta", "Alpha", "Beta"])
        XCTAssertTrue(events[0].id.hasPrefix("item-x@"))
        XCTAssertNil(events[0].location, "blank location reads as none")
    }

    // MARK: All-day

    func testAllDayEndingAtNextMidnightStaysOnItsDay() {
        let store = FakeCalendarEventStore()
        store.stored = [occurrence("holiday", "Holiday", date(2026, 10, 29), date(2026, 10, 30), allDay: true)]
        let source = source(store)
        XCTAssertEqual(source.events(in: day(2026, 10, 29)).count, 1)
        XCTAssertTrue(source.events(in: day(2026, 10, 30)).isEmpty)
        XCTAssertTrue(source.events(in: day(2026, 10, 28)).isEmpty)
    }

    func testAllDayEndingAt235959MapsToNextMidnight() {
        let store = FakeCalendarEventStore()
        store.stored = [occurrence("trip", "Trip", date(2026, 10, 29), date(2026, 10, 31, 23, 59, 59), allDay: true)]
        let source = source(store)
        let event = source.events(in: day(2026, 10, 30)).first
        XCTAssertEqual(event?.start, date(2026, 10, 29))
        XCTAssertEqual(event?.end, date(2026, 11, 1))
        XCTAssertEqual(source.events(in: day(2026, 10, 31)).count, 1)
        XCTAssertTrue(source.events(in: day(2026, 11, 1)).isEmpty)
    }

    func testAllDayZeroLengthCoversItsDay() {
        let store = FakeCalendarEventStore()
        store.stored = [occurrence("z", "Birthday", date(2026, 10, 29), date(2026, 10, 29), allDay: true)]
        let event = source(store).events(in: day(2026, 10, 29)).first
        XCTAssertEqual(event?.end, date(2026, 10, 30))
    }

    func testAllDayAcrossDaylightSavingEnd() {
        // London leaves summer time on 25 Oct 2026: that day is 25 hours long.
        let store = FakeCalendarEventStore()
        store.stored = [occurrence("dst", "Clocks", date(2026, 10, 25), date(2026, 10, 26), allDay: true)]
        let source = source(store)
        XCTAssertEqual(source.events(in: day(2026, 10, 25)).first?.end, date(2026, 10, 26))
        XCTAssertTrue(source.events(in: day(2026, 10, 26)).isEmpty)
    }

    // MARK: Floating

    func testFloatingEventKeepsEventKitDates() {
        let store = FakeCalendarEventStore()
        let start = date(2026, 10, 29, 23, 30)
        store.stored = [
            occurrence("float", "Late", start, date(2026, 10, 29, 23, 45), timeZone: nil),
            occurrence("tokyo", "Call", date(2026, 10, 29, 8), date(2026, 10, 29, 9), timeZone: TimeZone(identifier: "Asia/Tokyo")),
        ]
        let events = source(store).events(in: day(2026, 10, 29))
        XCTAssertEqual(events.map(\.title), ["Call", "Late"])
        XCTAssertEqual(events.last?.start, start, "a floating event is not shifted by any zone")
    }

    func testTimeZoneChangeAndStoreChangeCallOnChange() {
        let center = NotificationCenter()
        let source = source(FakeCalendarEventStore(), center: center)
        var calls = 0
        source.onChange = { calls += 1 }
        center.post(name: .EKEventStoreChanged, object: nil)
        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        XCTAssertEqual(calls, 2)
    }

    // MARK: Colour

    func testColourConvertsToSRGB() {
        let red = CGColor(srgbRed: 1, green: 0.2, blue: 0, alpha: 1)
        let mapped = EventKitCalendarEventSource.colour(from: red)
        XCTAssertEqual(mapped.red, 1, accuracy: 0.001)
        XCTAssertEqual(mapped.green, 0.2, accuracy: 0.001)
        XCTAssertEqual(mapped.blue, 0, accuracy: 0.001)

        let grey = CGColor(gray: 0.5, alpha: 1)
        let mappedGrey = EventKitCalendarEventSource.colour(from: grey)
        XCTAssertEqual(mappedGrey.red, mappedGrey.green, accuracy: 0.01)
        XCTAssertEqual(mappedGrey.green, mappedGrey.blue, accuracy: 0.01)

        let p3 = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: [0, 1, 0, 1])!
        let mappedP3 = EventKitCalendarEventSource.colour(from: p3)
        for component in [mappedP3.red, mappedP3.green, mappedP3.blue] {
            XCTAssertTrue((0...1).contains(component), "clamped into sRGB")
        }
        XCTAssertGreaterThan(mappedP3.green, 0.9)

        XCTAssertEqual(EventKitCalendarEventSource.colour(from: nil), EventKitCalendarEventSource.fallbackColour)
    }

    // MARK: Search

    func testSearchFiltersTitleAndLocation() {
        let store = FakeCalendarEventStore()
        store.stored = [
            occurrence("a", "Café meeting", date(2026, 10, 29, 9), date(2026, 10, 29, 10)),
            occurrence("b", "Gym", date(2026, 10, 30, 9), date(2026, 10, 30, 10), location: "Leisure Centre"),
            occurrence("c", "Dentist", date(2026, 10, 31, 9), date(2026, 10, 31, 10)),
        ]
        let source = source(store)
        let window = DateInterval(start: date(2026, 10, 1), end: date(2026, 12, 1))
        XCTAssertEqual(source.search("cafe", in: window).map(\.title), ["Café meeting"])
        XCTAssertEqual(source.search("leisure", in: window).map(\.title), ["Gym"])
        XCTAssertTrue(source.search("   ", in: window).isEmpty)
    }

    func testSearchOverMoreThanFourYearsSplitsQueriesAndDeduplicates() {
        let store = FakeCalendarEventStore()
        let window = DateInterval(start: date(2020, 1, 1), end: date(2031, 1, 1))
        let spans = EventKitCalendarEventSource.fetchSpans(for: window)
        XCTAssertGreaterThan(spans.count, 1)
        // A long event crossing the first boundary comes back from two queries.
        let boundary = spans[0].end
        store.stored = [
            occurrence("early", "Exam", date(2020, 6, 1, 9), date(2020, 6, 1, 11)),
            occurrence("cross", "Exam season", boundary.addingTimeInterval(-3_600), boundary.addingTimeInterval(3_600)),
            occurrence("late", "Exam resit", date(2030, 6, 1, 9), date(2030, 6, 1, 11)),
            occurrence("other", "Holiday", date(2025, 6, 1, 9), date(2025, 6, 1, 11)),
        ]
        let results = source(store).search("exam", in: window)
        XCTAssertEqual(results.map(\.title), ["Exam", "Exam season", "Exam resit"])
        XCTAssertGreaterThan(store.queries.count, 1)
        let fourYears: TimeInterval = 4 * 365 * 86_400
        XCTAssertTrue(store.queries.allSatisfy { $0.duration <= fourYears })
        XCTAssertLessThanOrEqual(store.queries.first!.start, window.start)
        XCTAssertGreaterThanOrEqual(store.queries.last!.end, window.end)
    }

    // MARK: Factory

    func testFactoryReturnsStubUnderTestsAndUITesting() {
        let unitHost = AppRuntimeEnvironment(environment: ["XCTestConfigurationFilePath": "/x"])
        XCTAssertTrue(CalendarEventSources.makeDefault(environment: unitHost) is CalendarEventSourceStub)
        let uiTesting = AppRuntimeEnvironment(environment: ["ATTIC_UI_TESTING": "1"])
        XCTAssertTrue(CalendarEventSources.makeDefault(environment: uiTesting) is CalendarEventSourceStub)
        let app = AppRuntimeEnvironment(environment: [:])
        XCTAssertTrue(CalendarEventSources.makeDefault(environment: app) is EventKitCalendarEventSource)
    }
}
