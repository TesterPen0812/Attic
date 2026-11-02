import Foundation
import XCTest
@testable import AtticMobile

@MainActor
final class PhoneCalendarTests: XCTestCase {
    private let day = DueDay(rawValue: "2026-10-28")!
    private var london: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private func occurrence(_ title: String, _ start: String, _ end: String, allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: title, title: title, start: date(start), end: date(end), isAllDay: allDay,
                      location: nil, calendarTitle: "Fixture", colour: .init(red: 0, green: 0, blue: 1))
    }

    private func backend() -> FakeCalendarEventWriteStore {
        let store = FakeCalendarEventWriteStore()
        store.availableCalendars = [.init(id: "fixture", title: "Fixture", colour: .init(red: 0, green: 0, blue: 1),
                                          sourceID: "local", sourceTitle: "Local", isWritable: true)]
        return store
    }

    private func library() throws -> PhoneLibrary {
        PhoneLibrary(container: try PersistenceController.makeContainer(inMemory: true))
    }

    func testSetupNeverPromptsOrFetchesAndUnavailableAccessStillListsDatedTasks() async throws {
        let source = ReadProbe(), store = backend()
        let phone = PhoneCalendar(source: source, store: store, record: try CalendarOwnershipRecord(), calendar: london)
        XCTAssertEqual(source.accessChecks, 0)
        XCTAssertEqual(source.asyncReads.count + source.syncReads + source.prompts, 0)
        let tasks = try library()
        try tasks.createTask(title: "Undated")
        try tasks.createTask(title: "On Wednesday", dueDay: day)
        try tasks.createTask(title: "On Thursday", dueDay: DueDay(rawValue: "2026-10-29"))
        for state in [CalendarAccessState.notDetermined, .restricted, .denied] {
            source.state = state
            let groups = await phone.agenda(starting: day, dayCount: 1, tasks: try tasks.tasks())
            XCTAssertEqual(groups.flatMap(\.rows).map(\.title), ["On Wednesday"])
            XCTAssertEqual(phone.accessState, state)
            XCTAssertThrowsError(try phone.writableCalendars()) { XCTAssertEqual($0 as? CalendarEventWriteError, .accessDenied) }
            XCTAssertThrowsError(try phone.openingURL(for: "fixture"))
        }
        XCTAssertEqual(source.asyncReads.count + source.syncReads + source.prompts, 0)
        XCTAssertTrue(store.opened.isEmpty)
        source.state = .granted
        _ = await phone.agenda(starting: day, dayCount: 3, tasks: [])
        XCTAssertEqual(source.asyncReads, [DateInterval(start: date("2026-10-28T00:00:00Z"), end: date("2026-10-31T00:00:00Z"))])
        XCTAssertEqual(source.syncReads + source.prompts, 0)
    }

    func testDrawnRowsMergeByTimeAndPastStateUsesTheEventEnd() async throws {
        let phone = try PhoneCalendar.synthetic(), tasks = try library()
        try tasks.createTask(title: "Review the launch checklist", dueDay: day, dueTimeMinutes: 15 * 60)
        try tasks.createTask(title: "Untimed", dueDay: day)
        let groups = await phone.agenda(starting: day, dayCount: 3, tasks: try tasks.tasks())
        XCTAssertEqual(groups.map { $0.day.rawValue }, ["2026-10-28", "2026-10-29", "2026-10-30"])
        let first = try XCTUnwrap(groups.first?.rows)
        XCTAssertEqual(first.map(\.title), ["Lecture: Data Structures", "Lunch with Sam", "Review the launch checklist",
                                           "Launch sync", "Pub quiz", "Untimed"])
        XCTAssertEqual(first.filter(\.isPast).map(\.title), ["Lecture: Data Structures", "Lunch with Sam"])
        let friday = try XCTUnwrap(groups.last?.rows)
        guard case let .event(birthday, _) = friday.first else { return XCTFail("Expected all-day event first") }
        XCTAssertTrue(birthday.isAllDay)
        XCTAssertEqual(friday.last?.title, "Seminar: Discrete Maths")
    }

    func testRevocationDuringReadDiscardsEventsButKeepsTasks() async throws {
        let source = ReadProbe(), tasks = try library()
        source.state = .granted
        source.stateAfterLoad = .denied
        source.result = [occurrence("Hidden", "2026-10-28T10:00:00Z", "2026-10-28T11:00:00Z")]
        try tasks.createTask(title: "Still visible", dueDay: day)
        let phone = PhoneCalendar(source: source, store: backend(), record: try CalendarOwnershipRecord(), calendar: london)
        let groups = await phone.agenda(starting: day, dayCount: 1, tasks: try tasks.tasks())
        XCTAssertEqual(groups.flatMap(\.rows).map(\.title), ["Still visible"])
        XCTAssertEqual(source.asyncReads.count, 1)
        XCTAssertEqual(source.prompts, 0)
    }

    func testDayBeginningAtOneAfterSkippedMidnightDoesNotFetchPartOfTomorrow() async throws {
        let selected = try XCTUnwrap(DueDay(rawValue: "2018-11-04")), source = ReadProbe()
        var dates = Calendar(identifier: .gregorian)
        dates.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Sao_Paulo"))
        source.state = .granted
        let phone = PhoneCalendar(source: source, store: backend(), record: try CalendarOwnershipRecord(), calendar: dates)
        let groups = await phone.agenda(starting: selected, dayCount: 1, tasks: [])
        XCTAssertEqual(groups.map(\.day), [selected])
        XCTAssertEqual(source.asyncReads, [DateInterval(start: date("2018-11-04T03:00:00Z"), end: date("2018-11-05T02:00:00Z"))])
    }

    func testAutumnOverlapIsHalfOpenAndFloatingClockUsesFirstRepeatedHour() async throws {
        let selected = try XCTUnwrap(DueDay(rawValue: "2026-10-25")), tasks = try library()
        try tasks.createTask(title: "01:45 first", dueDay: selected, dueTimeMinutes: 105)
        let events = [
            occurrence("Ends at midnight", "2026-10-24T22:00:00Z", "2026-10-24T23:00:00Z"),
            occurrence("Continues", "2026-10-24T22:30:00Z", "2026-10-24T23:30:00Z"),
            occurrence("Midnight instant", "2026-10-24T23:00:00Z", "2026-10-24T23:00:00Z"),
            occurrence("01:30 first", "2026-10-25T00:30:00Z", "2026-10-25T00:45:00Z"),
            occurrence("01:15 second", "2026-10-25T01:15:00Z", "2026-10-25T02:15:00Z"),
            occurrence("All day", "2026-10-24T23:00:00Z", "2026-10-26T00:00:00Z", allDay: true),
            occurrence("Next day", "2026-10-26T00:00:00Z", "2026-10-26T01:00:00Z")
        ]
        let source = CalendarEventSourceStub(events: Array(events.reversed()))
        let now = date("2026-10-25T01:30:00Z")
        let phone = PhoneCalendar(source: source, store: backend(), record: try CalendarOwnershipRecord(),
                                  calendar: london, now: { now })
        let groups = await phone.agenda(starting: selected, dayCount: 2, tasks: try tasks.tasks())
        let rows = try XCTUnwrap(groups.first?.rows)
        XCTAssertEqual(rows.map(\.title), ["All day", "Continues", "Midnight instant", "01:30 first", "01:45 first", "01:15 second"])
        XCTAssertEqual(rows.filter(\.isPast).map(\.title), ["Continues", "Midnight instant", "01:30 first"])
        XCTAssertEqual(groups.last?.rows.map(\.title), ["Next day"])
    }

    func testSpringGapClocksMoveToNextValidInstantInEnteredOrder() async throws {
        let selected = try XCTUnwrap(DueDay(rawValue: "2026-03-29")), tasks = try library()
        for (title, minutes) in [("01:50", 110), ("01:10", 70), ("02:00 task", 120)] {
            try tasks.createTask(title: title, dueDay: selected, dueTimeMinutes: minutes)
        }
        let source = CalendarEventSourceStub(events: [occurrence("02:00 event", "2026-03-29T01:00:00Z", "2026-03-29T01:01:00Z")])
        let phone = PhoneCalendar(source: source, store: backend(), record: try CalendarOwnershipRecord(), calendar: london)
        let groups = await phone.agenda(starting: selected, dayCount: 1, tasks: try tasks.tasks())
        XCTAssertEqual(groups.first?.rows.map(\.title), ["01:10", "01:50", "02:00 event", "02:00 task"])
    }

    func testSyntheticRunsHaveStableIDsAndReadTheirOwnCommittedWrites() async throws {
        @MainActor
        func exercise(_ phone: PhoneCalendar) async throws -> [String] {
            let groups = await phone.agenda(starting: day, dayCount: 1, tasks: [])
            let rows = try XCTUnwrap(groups.first?.rows)
            guard case let .event(lecture, _) = rows.first,
                  case let .event(sync, _) = rows.first(where: { $0.title == "Launch sync" }) else {
                XCTFail("Missing fixture events"); return []
            }
            XCTAssertEqual(try phone.controls(for: lecture.id), .openOnly)
            XCTAssertNil(try phone.openingURL(for: lecture.id))
            guard case let .owned(seed) = try phone.controls(for: sync.id) else { XCTFail("Missing seed proof"); return [] }
            var draft = seed.draft
            draft.title = "New event"; draft.notes = "Keep this"
            var changes = 0
            phone.onChange = { changes += 1 }
            let made = try phone.create(draft)
            let created = await phone.agenda(starting: day, dayCount: 1, tasks: [])
            XCTAssertTrue(created.flatMap(\.rows).contains { $0.title == "New event" })
            var renamed = made.draft
            renamed.title = "Renamed"; renamed.notes = nil
            let saved = try phone.edit(made, draft: renamed)
            XCTAssertEqual(saved.draft.notes, "Keep this")
            let edited = await phone.agenda(starting: day, dayCount: 1, tasks: [])
            XCTAssertTrue(edited.flatMap(\.rows).contains { $0.title == "Renamed" })
            XCTAssertEqual(try phone.controls(for: saved.occurrenceID), .owned(saved))
            try phone.delete(saved)
            let deleted = await phone.agenda(starting: day, dayCount: 1, tasks: [])
            XCTAssertEqual(deleted.flatMap(\.rows).map(\.id), rows.map(\.id))
            XCTAssertEqual(try phone.controls(for: saved.occurrenceID), .openOnly)
            XCTAssertEqual(changes, 3)
            return rows.map(\.id) + [seed.id.uuidString, made.id.uuidString, made.occurrenceID]
        }
        let first = try await exercise(PhoneCalendar.synthetic())
        let second = try await exercise(PhoneCalendar.synthetic())
        XCTAssertEqual(first, second)
    }

    func testStaleDetailCannotEditOrDeleteAfterExternalChangesOrLossOfWriteAccess() throws {
        let store = backend(), source = CalendarEventSourceStub()
        let phone = PhoneCalendar(source: source, store: store, record: try CalendarOwnershipRecord(), calendar: london)
        let draft = CalendarEventDraft(title: "Mine", start: date("2026-10-28T10:00:00Z"), length: 1800,
                                       calendarID: "fixture", timeZoneID: "UTC", notes: "Original")
        let made = try phone.create(draft)
        guard case let .owned(detail) = try phone.controls(for: made.occurrenceID) else { return XCTFail("Expected ownership") }
        let original = try XCTUnwrap(store.events.values.first)
        var changedNotes = original; changedNotes.draft.notes = "Someone else's notes"
        var changedMetadata = original; changedMetadata.metadata = "Someone else's location"
        var recurring = original; recurring.isRepeating = true
        for (snapshot, writable, reason) in [(changedNotes, true, CalendarEventWriteError.eventChanged),
                                             (changedMetadata, true, .eventChanged), (recurring, true, .repeatingEvent),
                                             (original, false, .calendarReadOnly)] {
            store.events[original.eventIdentifier] = snapshot
            store.availableCalendars[0].isWritable = writable
            XCTAssertEqual(try phone.controls(for: made.occurrenceID), .openOnly)
            XCTAssertThrowsError(try phone.edit(detail, draft: draft)) { XCTAssertEqual($0 as? CalendarEventWriteError, reason) }
            XCTAssertThrowsError(try phone.delete(detail)) { XCTAssertEqual($0 as? CalendarEventWriteError, reason) }
            XCTAssertEqual(store.events[original.eventIdentifier], snapshot)
        }
        XCTAssertEqual(store.commits, 1)
        XCTAssertNil(try phone.openingURL(for: made.occurrenceID))
        XCTAssertEqual(store.opened, [made.occurrenceID])
    }

    func testEarlierEditorCannotOverwriteANewerOwnedNotesOnlyEdit() throws {
        let store = backend()
        let phone = PhoneCalendar(source: CalendarEventSourceStub(), store: store, record: try CalendarOwnershipRecord(), calendar: london)
        var draft = CalendarEventDraft(title: "Mine", start: date("2026-10-28T10:00:00Z"), length: 1800,
                                       calendarID: "fixture", timeZoneID: "UTC", notes: "Before")
        let first = try phone.create(draft)
        draft.notes = "After"
        let latest = try phone.edit(first, draft: draft)
        XCTAssertThrowsError(try phone.edit(first, draft: first.draft)) { XCTAssertEqual($0 as? CalendarEventWriteError, .eventChanged) }
        XCTAssertThrowsError(try phone.delete(first)) { XCTAssertEqual($0 as? CalendarEventWriteError, .eventChanged) }
        XCTAssertEqual(try phone.controls(for: first.occurrenceID), .owned(latest))
        XCTAssertEqual(store.commits, 2)
    }
}

@MainActor
private final class ReadProbe: CalendarEventSource, AsyncCalendarEventReading {
    var state: CalendarAccessState = .notDetermined
    var stateAfterLoad: CalendarAccessState?
    var result: [CalendarEvent] = []
    var accessState: CalendarAccessState { accessChecks += 1; return state }
    var onChange: (@MainActor () -> Void)?
    private(set) var accessChecks = 0, syncReads = 0, prompts = 0
    private(set) var asyncReads: [DateInterval] = []
    func requestAccess() async -> CalendarAccessState { prompts += 1; return state }
    func events(in interval: DateInterval) -> [CalendarEvent] { syncReads += 1; return [] }
    func loadEvents(in interval: DateInterval) async -> [CalendarEvent] {
        asyncReads.append(interval)
        if let stateAfterLoad { state = stateAfterLoad }
        return result
    }
    func search(_ text: String, in interval: DateInterval) -> [CalendarEvent] { [] }
}
