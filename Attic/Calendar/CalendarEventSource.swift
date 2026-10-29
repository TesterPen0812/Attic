import Foundation

// The contract between the Calendar page and where its events come from. The
// page reads events only through `CalendarEventSource`; the EventKit source and
// the stub both conform, so the source can change without touching the page.
// Read-only by design: nothing here writes to a calendar.

/// Whether Attic may read the person's calendars.
enum CalendarAccessState: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
    case restricted
}

/// A calendar's colour as sRGB components in 0...1.
struct CalendarEventColour: Equatable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
}

/// One occurrence of an event; a repeating event yields one per occurrence.
struct CalendarEvent: Identifiable, Equatable, Hashable, Sendable {
    /// Stable per occurrence: the event's identifier plus the occurrence start.
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
    var calendarTitle: String
    var colour: CalendarEventColour

    /// True when the occurrence overlaps `interval`. An event that ends exactly
    /// where the interval starts does not overlap it; a zero-length event at the
    /// interval's start does.
    func overlaps(_ interval: DateInterval) -> Bool {
        guard start < interval.end else { return false }
        return end > interval.start || (end == start && start >= interval.start)
    }

    /// Case- and diacritic-insensitive match on the title or location.
    func matches(_ text: String) -> Bool {
        title.localizedStandardContains(text) || (location?.localizedStandardContains(text) ?? false)
    }
}

/// A read-only source of calendar events for the Calendar page.
@MainActor
protocol CalendarEventSource: AnyObject {
    var accessState: CalendarAccessState { get }
    /// Asks for access when it hasn't been decided yet; never prompts again
    /// after a denial. Returns the state afterwards.
    func requestAccess() async -> CalendarAccessState
    /// Occurrences overlapping `interval`, sorted by start, then title.
    func events(in interval: DateInterval) -> [CalendarEvent]
    /// Occurrences in `interval` whose title or location contains `text`,
    /// sorted by start, then title. Empty or blank text matches nothing.
    func search(_ text: String, in interval: DateInterval) -> [CalendarEvent]
    /// Called on the main actor whenever the underlying calendars change.
    var onChange: (@MainActor () -> Void)? { get set }
}

extension Array where Element == CalendarEvent {
    /// The order every source returns: by start, then title.
    func sortedForAgenda() -> [CalendarEvent] {
        sorted { $0.start != $1.start ? $0.start < $1.start : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

/// Fixed events for previews, tests and builds without calendar access.
@MainActor
final class CalendarEventSourceStub: CalendarEventSource {
    var accessState: CalendarAccessState
    var onChange: (@MainActor () -> Void)?
    private(set) var storedEvents: [CalendarEvent]

    init(accessState: CalendarAccessState = .granted, events: [CalendarEvent] = []) {
        self.accessState = accessState
        self.storedEvents = events
    }

    func requestAccess() async -> CalendarAccessState { accessState }

    func events(in interval: DateInterval) -> [CalendarEvent] {
        guard accessState == .granted else { return [] }
        return storedEvents.filter { $0.overlaps(interval) }.sortedForAgenda()
    }

    func search(_ text: String, in interval: DateInterval) -> [CalendarEvent] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return events(in: interval).filter { $0.matches(query) }
    }

    func replace(_ events: [CalendarEvent]) {
        storedEvents = events
        onChange?()
    }
}
