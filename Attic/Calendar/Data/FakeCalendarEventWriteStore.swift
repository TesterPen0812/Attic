import Foundation

/// Transactional fake used by hosted tests. Never creates an EKEventStore.
@MainActor
final class FakeCalendarEventWriteStore: CalendarEventWriteStore {
    var accessState: CalendarAccessState = .granted
    var availableCalendars: [CalendarWriteCalendar] = []
    var events: [String: CalendarWriteSnapshot] = [:]
    var stageError: CalendarEventWriteError?
    var commitError: CalendarEventWriteError?
    var openError: CalendarEventWriteError?
    private(set) var opened: [String] = []
    private(set) var commits = 0
    private(set) var rollbacks = 0
    private var staged: [String: CalendarWriteSnapshot]?

    func calendars() -> [CalendarWriteCalendar] { availableCalendars }
    func event(identifier: String) -> CalendarWriteSnapshot? {
        events[identifier] ?? events.values.first { $0.itemIdentifier == identifier }
    }

    func stageCreate(_ draft: CalendarEventDraft, marker: String) throws -> CalendarWriteSnapshot {
        if let stageError { throw stageError }
        let event = CalendarWriteSnapshot(eventIdentifier: UUID().uuidString,
                                          itemIdentifier: UUID().uuidString, marker: marker, draft: draft)
        staged = events
        staged?[event.eventIdentifier] = event
        return event
    }

    func stageEdit(_ previous: CalendarWriteSnapshot, draft: CalendarEventDraft) throws -> CalendarWriteSnapshot {
        if let stageError { throw stageError }
        guard events[previous.eventIdentifier] == previous else { throw CalendarEventWriteError.eventChanged }
        var updated = previous
        updated.draft = draft
        // Moving calendars may change EventKit's ID.
        if draft.calendarID != previous.draft.calendarID { updated.eventIdentifier = UUID().uuidString }
        staged = events
        staged?[previous.eventIdentifier] = nil
        staged?[updated.eventIdentifier] = updated
        return updated
    }

    func stageDelete(_ previous: CalendarWriteSnapshot) throws {
        if let stageError { throw stageError }
        guard events[previous.eventIdentifier] == previous else { throw CalendarEventWriteError.eventChanged }
        staged = events
        staged?[previous.eventIdentifier] = nil
    }

    func commit() throws {
        if let commitError { throw commitError }
        if let staged { events = staged }
        staged = nil
        commits += 1
    }

    func rollback() { staged = nil; rollbacks += 1 }
    func openInCalendar(_ occurrenceID: String) throws {
        if let openError { throw openError }
        opened.append(occurrenceID)
    }
}
