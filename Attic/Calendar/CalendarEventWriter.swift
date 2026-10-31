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
    /// The event's notes: the "+" card's writing line. nil leaves the
    /// event's notes as they are. Plain writing only: Attic never puts a
    /// marker here (ownership stays in the local record).
    var notes: String?

    init(title: String, start: Date, end: Date, isAllDay: Bool = false,
         calendarID: String, timeZoneID: String = TimeZone.current.identifier, notes: String? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarID = calendarID
        self.timeZoneID = timeZoneID
        self.notes = notes
    }

    init(title: String, start: Date, length: TimeInterval, calendarID: String,
         timeZoneID: String = TimeZone.current.identifier, notes: String? = nil) {
        self.init(title: title, start: start, end: start.addingTimeInterval(length),
                  calendarID: calendarID, timeZoneID: timeZoneID, notes: notes)
    }

    /// Match civil dates for floating all-day events, independent of travel.
    /// Timed events retain their absolute dates and explicit zone.
    func hasSameOwnedValues(as other: Self) -> Bool {
        guard title == other.title, calendarID == other.calendarID, isAllDay == other.isAllDay else { return false }
        if !isAllDay { return start == other.start && end == other.end && timeZoneID == other.timeZoneID }
        func days(_ draft: Self) -> [DateComponents] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: draft.timeZoneID) ?? .autoupdatingCurrent
            return [draft.start, draft.end].map { calendar.dateComponents([.year, .month, .day], from: $0) }
        }
        return days(self) == days(other)
    }

    var roundedToMinutes: Self {
        guard !isAllDay else { return self }
        var rounded = self
        rounded.start = Date(timeIntervalSinceReferenceDate: (start.timeIntervalSinceReferenceDate / 60).rounded() * 60)
        rounded.end = Date(timeIntervalSinceReferenceDate: (end.timeIntervalSinceReferenceDate / 60).rounded() * 60)
        return rounded
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

/// Local proof: EventKit identity and the captured user-visible values. Attic
/// never writes a URL or other marker into events. Provider alarms/availability
/// are observations only and do not participate in ownership matching.
struct CalendarWriteSnapshot: Codable, Equatable {
    var eventIdentifier: String
    var itemIdentifier: String
    var draft: CalendarEventDraft
    var isRepeating: Bool = false
    var metadata: String = ""
    var url: String? = nil
    var alarms: [TimeInterval] = []
    var availability: Int = 0

    private enum CodingKeys: String, CodingKey {
        case eventIdentifier, itemIdentifier, draft, isRepeating, metadata, url
    }

    func matchesOwnership(of proof: Self) -> Bool {
        itemIdentifier == proof.itemIdentifier && !isRepeating && !proof.isRepeating
            && draft.hasSameOwnedValues(as: proof.draft) && metadata == proof.metadata
            && (url ?? "") == (proof.url ?? "")
    }

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
    /// Live EventKit already posts its own notification. Fakes normally rely
    /// on the engine, or may simulate that native notification themselves.
    var postsChangeNotifications: Bool { get }
    func calendars() -> [CalendarWriteCalendar]
    /// Fresh committed state, looked up by event OR calendar-item identifier.
    func event(identifier: String) -> CalendarWriteSnapshot?
    func stageCreate(_ draft: CalendarEventDraft) throws -> CalendarWriteSnapshot
    func stageEdit(_ previous: CalendarWriteSnapshot, draft: CalendarEventDraft) throws -> CalendarWriteSnapshot
    func stageDelete(_ previous: CalendarWriteSnapshot) throws
    func commit() throws
    func rollback()
    func openInCalendar(_ occurrenceID: String) throws
}

extension CalendarEventWriteStore {
    var postsChangeNotifications: Bool { false }
}
