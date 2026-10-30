import Foundation

/// Stable calendar and source identifiers distinguish equally named calendars.
struct CalendarWriteCalendar: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var colour: CalendarEventColour
    var sourceID: String
    var sourceTitle: String
    var isWritable: Bool
}

/// End is exclusive, including for all-day events. All-day bounds must be
/// local midnights in `timeZoneID`; use calendar-day arithmetic across DST.
struct CalendarEventDraft: Codable, Equatable, Sendable {
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var calendarID: String
    var timeZoneID: String

    init(title: String, start: Date, end: Date, isAllDay: Bool = false,
         calendarID: String, timeZoneID: String = TimeZone.current.identifier) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarID = calendarID
        self.timeZoneID = timeZoneID
    }

    init(title: String, start: Date, length: TimeInterval, calendarID: String,
         timeZoneID: String = TimeZone.current.identifier) {
        self.init(title: title, start: start, end: start.addingTimeInterval(length),
                  calendarID: calendarID, timeZoneID: timeZoneID)
    }
}

enum CalendarEventWriteError: Error, Equatable {
    case accessDenied
    case invalidDraft
    case calendarMissing
    case calendarReadOnly
    case notOwned
    case eventMissing
    case eventChanged
    case repeatingEvent
    case saveFailed(String)
    case recordFailed(String)
    case openFailed
    case undoUnavailable
}

/// This local UUID survives delete/Undo, even when EventKit assigns new IDs.
struct CalendarOwnedEvent: Identifiable, Equatable {
    var id: UUID
    var occurrenceID: String
    var draft: CalendarEventDraft
}

/// Engine only. Call from the Calendar page once its composer/event UI ships.
/// Other pages retain their read-only source and navigate to Calendar.
@MainActor
protocol CalendarEventWriter: AnyObject {
    var lastError: CalendarEventWriteError? { get }
    func writableCalendars() throws -> [CalendarWriteCalendar]
    func ownedEvent(matching occurrenceID: String) throws -> CalendarOwnedEvent?
    func create(_ draft: CalendarEventDraft) throws -> CalendarOwnedEvent
    func edit(_ id: UUID, draft: CalendarEventDraft) throws -> CalendarOwnedEvent
    func delete(_ id: UUID) throws
    func openInCalendar(_ occurrenceID: String) throws
}

/// Persisted proof: both EventKit IDs, a random URL marker and the complete
/// editable values must match. Additional metadata is compared conservatively.
struct CalendarWriteSnapshot: Codable, Equatable {
    var eventIdentifier: String
    var itemIdentifier: String
    var marker: String
    var draft: CalendarEventDraft
    var isRepeating: Bool = false
    var metadata: String = ""

    var occurrenceID: String {
        "\(eventIdentifier)@\(draft.start.timeIntervalSinceReferenceDate)"
    }
}

/// Mutations are staged, not committed, until their ownership proof is durable.
/// Implementations must discard ALL staged changes on rollback and never share
/// their transactional store with unrelated writers.
@MainActor
protocol CalendarEventWriteStore: AnyObject {
    var accessState: CalendarAccessState { get }
    func calendars() -> [CalendarWriteCalendar]
    /// Fresh committed state, looked up by event OR calendar-item identifier.
    func event(identifier: String) -> CalendarWriteSnapshot?
    func stageCreate(_ draft: CalendarEventDraft, marker: String) throws -> CalendarWriteSnapshot
    func stageEdit(_ previous: CalendarWriteSnapshot, draft: CalendarEventDraft) throws -> CalendarWriteSnapshot
    func stageDelete(_ previous: CalendarWriteSnapshot) throws
    func commit() throws
    func rollback()
    func openInCalendar(_ occurrenceID: String) throws
}
