import Foundation

/// Owns an injected read source and a serial, synchronous ownership transaction adapter.
/// Stage 2 uses only the in-memory pair in `synthetic()`. Construction does no I/O.
@MainActor
final class PhoneCalendar {
    enum Row: Identifiable {
        case event(CalendarEvent, isPast: Bool)
        case task(PhoneLibrary.TaskRow)

        var id: String {
            switch self {
            case let .event(event, _): return "event-" + event.id
            case let .task(task): return "task-" + task.id.uuidString
            }
        }
        var title: String {
            switch self {
            case let .event(event, _): return event.title
            case let .task(task): return task.title
            }
        }
        var isPast: Bool {
            if case let .event(_, past) = self { return past }
            return false
        }
    }

    struct Day: Identifiable {
        let day: DueDay
        let rows: [Row]
        var id: DueDay { day }
    }

    /// Only an owned detail offers Edit/Delete. Pass that detail back unchanged as the baseline.
    enum Controls: Equatable {
        case openOnly
        case owned(CalendarOwnedEvent)
    }

    private let source: CalendarEventSource
    private let store: CalendarEventWriteStore
    private let record: CalendarOwnershipRecord
    private let transactions: CalendarEventTransactions
    private let calendar: Calendar
    private let now: () -> Date
    private let makeID: () -> UUID
    private let publishWrite: () -> Void

    init(source: CalendarEventSource, store: CalendarEventWriteStore, record: CalendarOwnershipRecord,
         calendar: Calendar = .autoupdatingCurrent, now: @escaping () -> Date = Date.init,
         makeID: @escaping () -> UUID = UUID.init, publishWrite: (() -> Void)? = nil) {
        self.source = source
        self.store = store
        self.record = record
        self.transactions = CalendarEventTransactions(store: store, record: record)
        self.calendar = DueDay.storageCalendar(matching: calendar)
        self.now = now
        self.makeID = makeID
        self.publishWrite = publishWrite ?? { source.onChange?() }
    }

    var accessState: CalendarAccessState { source.accessState }
    var onChange: (@MainActor () -> Void)? {
        get { source.onChange }
        set { source.onChange = newValue }
    }

    /// One event read for the visible days. Task rows are the library's existing, ordered snapshots,
    /// including dated subtasks and Done rows on their due day. No request-access path is involved.
    func agenda(starting day: DueDay, dayCount: Int = 7, tasks: [PhoneLibrary.TaskRow]) async -> [Day] {
        guard dayCount > 0, let date = day.startDate(in: calendar) else { return [] }
        let start = calendar.startOfDay(for: date)
        guard let following = calendar.date(byAdding: .day, value: dayCount, to: start) else { return [] }
        // Midnight itself can be skipped. Adding a day from 01:00 must still end at the next day's start.
        let end = calendar.startOfDay(for: following)
        guard end > start else { return [] }
        let interval = DateInterval(start: start, end: end)
        var events: [CalendarEvent] = []
        if accessState == .granted {
            if let reader = source as? AsyncCalendarEventReading { events = await reader.loadEvents(in: interval) }
            else { events = source.events(in: interval) }
            if accessState != .granted { events = [] }
        }
        let clock = now(), tasksByDay = Dictionary(grouping: tasks, by: \.dueDay)
        let today = DueDay(date: clock, calendar: calendar)
        var result: [Day] = [], cursor = start
        while cursor < end, let bounds = calendar.dateInterval(of: .day, for: cursor), bounds.end > cursor {
            let date = DueDay(date: cursor, calendar: calendar)
            result.append(Day(day: date, rows: rows(in: bounds, day: date, today: today, now: clock,
                                                    events: events, tasks: tasksByDay[date] ?? [])))
            cursor = bounds.end
        }
        return result
    }

    private func rows(in bounds: DateInterval, day: DueDay, today: DueDay, now: Date,
                      events: [CalendarEvent], tasks: [PhoneLibrary.TaskRow]) -> [Row] {
        // Preserve absolute event instants during the autumn fold. Floating task times use the
        // first repeated hour; in a spring gap their entered minutes break ties at the next instant.
        var allDay: [Row] = [], untimed: [Row] = []
        var timed: [(instant: Date, minute: Int, row: Row)] = []
        let overlapping = events.filter { $0.overlaps(bounds) }.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            let title = lhs.title.localizedStandardCompare(rhs.title)
            return title == .orderedSame ? lhs.id < rhs.id : title == .orderedAscending
        }
        for event in overlapping {
            let past = day < today || (day == today && !event.isAllDay && event.end <= now)
            let row = Row.event(event, isPast: past)
            if event.isAllDay { allDay.append(row) }
            else {
                let minute = calendar.component(.hour, from: event.start) * 60 + calendar.component(.minute, from: event.start)
                timed.append((event.start, minute, row))
            }
        }
        for task in tasks {
            guard let minute = task.dueTimeMinutes, (0..<1440).contains(minute),
                  let instant = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0,
                                              of: bounds.start, matchingPolicy: .nextTime, repeatedTimePolicy: .first),
                  instant < bounds.end else { untimed.append(.task(task)); continue }
            timed.append((instant, minute, .task(task)))
        }
        let timeline = timed.enumerated().sorted { lhs, rhs in
            if lhs.element.instant != rhs.element.instant { return lhs.element.instant < rhs.element.instant }
            if lhs.element.minute != rhs.element.minute { return lhs.element.minute < rhs.element.minute }
            // Events precede tasks at the same clock; otherwise preserve source/library order.
            return lhs.offset < rhs.offset
        }
        return allDay + timeline.map { $0.element.row } + untimed
    }

    func writableCalendars() throws -> [CalendarWriteCalendar] {
        try perform { try transactions.writableCalendars() }
    }

    func controls(for occurrenceID: String) throws -> Controls {
        try perform {
            guard let owned = try transactions.ownedEvent(matching: occurrenceID),
                  let proof = record.entries[owned.id], proof.draft.notes == owned.draft.notes else { return .openOnly }
            return .owned(owned)
        }
    }

    @discardableResult
    func create(_ draft: CalendarEventDraft) throws -> CalendarOwnedEvent {
        try perform { try transactions.insert(makeID(), draft: draft) }
    }

    @discardableResult
    func edit(_ detail: CalendarOwnedEvent, draft: CalendarEventDraft) throws -> CalendarOwnedEvent {
        try perform {
            try requireUnchanged(detail)
            var edit = draft
            if edit.notes == nil { edit.notes = detail.draft.notes }
            return try transactions.update(detail.id, draft: edit, expecting: detail.draft)
        }
    }

    func delete(_ detail: CalendarOwnedEvent) throws {
        try perform {
            try requireUnchanged(detail)
            try transactions.remove(detail.id, expecting: detail.draft)
        }
    }

    /// An explicit handoff only. The synthetic backend returns nil; this layer never opens an app.
    func openingURL(for occurrenceID: String) throws -> URL? {
        try perform { try transactions.openingURL(occurrenceID) }
    }

    private func requireUnchanged(_ detail: CalendarOwnedEvent) throws {
        let live = try transactions.current(detail.id)
        guard live.occurrenceID == detail.occurrenceID, live.draft.hasSameOwnedValues(as: detail.draft),
              live.draft.notes == detail.draft.notes, let proof = record.entries[detail.id],
              proof.draft.notes == live.draft.notes else { throw CalendarEventWriteError.eventChanged }
    }

    private func perform<T>(_ action: () throws -> T) throws -> T {
        guard accessState == .granted, store.accessState == .granted else { throw CalendarEventWriteError.accessDenied }
        defer { if transactions.takeNotification() { publishWrite() } }
        return try action()
    }
}

extension PhoneCalendar {
    /// A + rows 2 run fixture. The reference Wednesday, its clock, both sets of IDs and the
    /// calendars are fixed. The runner can move the same four-day scenario to another civil day.
    static func synthetic(starting day: DueDay = DueDay(rawValue: "2026-10-28")!) throws -> PhoneCalendar {
        var dates = Calendar(identifier: .gregorian)
        dates.timeZone = TimeZone(identifier: "Europe/London")!
        guard let first = day.startDate(in: dates) else { throw CalendarEventWriteError.invalidDraft }
        func at(_ offset: Int, _ hour: Int = 0, _ minute: Int = 0) throws -> Date {
            guard let date = dates.date(byAdding: .day, value: offset, to: first),
                  let result = dates.date(bySettingHour: hour, minute: minute, second: 0, of: date)
            else { throw CalendarEventWriteError.invalidDraft }
            return result
        }
        let backend = PhoneCalendarFixtureStore()
        let zone = dates.timeZone.identifier
        func seed(_ key: String, _ title: String, _ calendarID: String, _ offset: Int, _ hour: Int, allDay: Bool = false) throws {
            let start = try at(offset, hour)
            let end = allDay ? try at(offset + 1) : start.addingTimeInterval(3600)
            backend.seedExternal(key, draft: .init(title: title, start: start, end: end, isAllDay: allDay,
                                                   calendarID: calendarID, timeZoneID: zone))
        }
        try seed("lecture", "Lecture: Data Structures", "uni", 0, 10)
        try seed("lunch", "Lunch with Sam", "personal", 0, 13)
        try seed("quiz", "Pub quiz", "personal", 0, 19)
        try seed("engineer", "Boiler engineer visit", "house", 1, 9)
        try seed("card", "Collect Warwick ID card", "uni", 1, 14)
        try seed("birthday", "Mum’s birthday", "personal", 2, 0, allDay: true)
        try seed("seminar", "Seminar: Discrete Maths", "uni", 2, 11)
        try seed("party", "Halloween party", "personal", 3, 20)

        let source = CalendarEventSourceStub(events: backend.occurrences)
        let clock = try at(0, 14, 30)
        var serial: UInt64 = 0
        let phone = PhoneCalendar(source: source, store: backend, record: try CalendarOwnershipRecord(),
                                  calendar: dates, now: { clock }, makeID: {
            serial += 1
            return UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", serial))!
        }, publishWrite: { source.replace(backend.occurrences) })
        // The seed gets the same journal proof as an event created by the user in this run.
        try phone.create(.init(title: "Launch sync", start: try at(0, 16, 30), length: 1800, calendarID: "work", timeZoneID: zone))
        return phone
    }
}

/// A deterministic substitute for the EventKit boundary, not a second ownership engine.
/// Only committed snapshots feed the shared read stub; no disk, system store or system notifications.
private final class PhoneCalendarFixtureStore: CalendarEventWriteStore {
    let accessState: CalendarAccessState = .granted
    private let choices: [CalendarWriteCalendar] = [
        ("uni", "University", CalendarEventColour(red: 0.25, green: 0.55, blue: 0.87)),
        ("personal", "Personal", .init(red: 0.25, green: 0.65, blue: 0.4)),
        ("work", "Work", .init(red: 0.64, green: 0.45, blue: 0.85)),
        ("house", "House", .init(red: 0.1, green: 0.63, blue: 0.65))
    ].map { CalendarWriteCalendar(id: $0.0, title: $0.1, colour: $0.2, sourceID: "fixture", sourceTitle: "Synthetic", isWritable: true) }

    private var events: [String: CalendarWriteSnapshot] = [:]
    private var serial = 0
    private enum Change { case save(CalendarWriteSnapshot), remove(String) }
    private var staged: Change?

    var occurrences: [CalendarEvent] {
        events.values.compactMap { snapshot in
            let draft = snapshot.draft
            guard let calendar = choices.first(where: { $0.id == draft.calendarID }) else { return nil }
            return CalendarEvent(id: snapshot.occurrenceID, title: draft.title, start: draft.start, end: draft.end,
                                 isAllDay: draft.isAllDay, location: nil, calendarTitle: calendar.title, colour: calendar.colour)
        }
    }

    func seedExternal(_ key: String, draft: CalendarEventDraft) {
        events[key] = CalendarWriteSnapshot(eventIdentifier: key, itemIdentifier: key, draft: draft)
    }
    func calendars() -> [CalendarWriteCalendar] { choices }
    func event(identifier: String) -> CalendarWriteSnapshot? { events[identifier] }

    func stageCreate(_ draft: CalendarEventDraft) throws -> CalendarWriteSnapshot {
        serial += 1
        let key = "created-\(serial)"
        return stage(CalendarWriteSnapshot(eventIdentifier: key, itemIdentifier: key, draft: draft), draft: draft)
    }
    func stageEdit(_ previous: CalendarWriteSnapshot, draft: CalendarEventDraft) throws -> CalendarWriteSnapshot {
        guard events[previous.itemIdentifier] == previous else { throw CalendarEventWriteError.eventChanged }
        return stage(previous, draft: draft)
    }
    private func stage(_ snapshot: CalendarWriteSnapshot, draft: CalendarEventDraft) -> CalendarWriteSnapshot {
        var next = snapshot
        next.draft = draft
        let notes = draft.notes ?? snapshot.draft.notes
        next.draft.notes = notes?.isEmpty == false ? notes : nil
        next.metadata = next.draft.notes ?? "" // The live store includes notes in its metadata proof too.
        staged = .save(next)
        return next
    }
    func stageDelete(_ previous: CalendarWriteSnapshot) throws {
        guard events[previous.itemIdentifier] == previous else { throw CalendarEventWriteError.eventChanged }
        staged = .remove(previous.itemIdentifier)
    }
    func commit() throws {
        switch staged {
        case let .save(snapshot): events[snapshot.itemIdentifier] = snapshot
        case let .remove(key): events[key] = nil
        case nil: throw CalendarEventWriteError.saveFailed("No staged synthetic event.")
        }
        staged = nil
    }
    func rollback() { staged = nil }
    func openInCalendar(_ occurrenceID: String) throws -> URL? {
        guard events.values.contains(where: { $0.occurrenceID == occurrenceID }) else { throw CalendarEventWriteError.eventMissing }
        return nil
    }
}
