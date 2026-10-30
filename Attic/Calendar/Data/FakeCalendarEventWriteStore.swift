import EventKit
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
    /// EventKit may allocate/change the event ID only at commit.
    var assignsEventIdentifiersOnCommit = false
    var normalizesOnCommit = false
    var landsThenThrowsOnCommit = false
    var postsChangeNotifications = false
    var notificationCenter = NotificationCenter.default
    private(set) var lastStagedDraft: CalendarEventDraft?
    private(set) var opened: [String] = []
    private(set) var commits = 0
    private(set) var rollbacks = 0
    private enum Mutation {
        case save(replacing: String?, snapshot: CalendarWriteSnapshot)
        case delete(String)
    }
    private var staged: Mutation?

    func calendars() -> [CalendarWriteCalendar] { availableCalendars }
    func event(identifier: String) -> CalendarWriteSnapshot? {
        events[identifier] ?? events.values.first { $0.itemIdentifier == identifier }
    }

    func stageCreate(_ draft: CalendarEventDraft) throws -> CalendarWriteSnapshot {
        if let stageError { throw stageError }
        lastStagedDraft = draft
        let itemID = UUID().uuidString
        let event = CalendarWriteSnapshot(eventIdentifier: assignsEventIdentifiersOnCommit ? itemID : UUID().uuidString,
                                          itemIdentifier: itemID, draft: draft)
        staged = .save(replacing: nil, snapshot: event)
        return event
    }

    func stageEdit(_ previous: CalendarWriteSnapshot, draft: CalendarEventDraft) throws -> CalendarWriteSnapshot {
        if let stageError { throw stageError }
        lastStagedDraft = draft
        guard events[previous.eventIdentifier] == previous else { throw CalendarEventWriteError.eventChanged }
        var updated = previous
        updated.draft = draft
        // Moving calendars may change EventKit's ID.
        if draft.calendarID != previous.draft.calendarID { updated.eventIdentifier = UUID().uuidString }
        staged = .save(replacing: previous.eventIdentifier, snapshot: updated)
        return updated
    }

    func stageDelete(_ previous: CalendarWriteSnapshot) throws {
        if let stageError { throw stageError }
        guard events[previous.eventIdentifier] == previous else { throw CalendarEventWriteError.eventChanged }
        staged = .delete(previous.eventIdentifier)
    }

    func commit() throws {
        if let commitError { throw commitError }
        switch staged {
        case let .save(replacing, snapshot):
            if let replacing { events[replacing] = nil }
            var committed = snapshot
            if assignsEventIdentifiersOnCommit { committed.eventIdentifier = UUID().uuidString }
            if normalizesOnCommit {
                committed.draft.start = Date(timeIntervalSinceReferenceDate: floor(committed.draft.start.timeIntervalSinceReferenceDate / 60) * 60)
                committed.draft.end = Date(timeIntervalSinceReferenceDate: floor(committed.draft.end.timeIntervalSinceReferenceDate / 60) * 60)
                committed.eventIdentifier = UUID().uuidString
                committed.url = nil
                committed.alarms = [-900]
                committed.availability = 1
            }
            events[committed.eventIdentifier] = committed
        case let .delete(identifier): events[identifier] = nil
        case nil: break
        }
        staged = nil
        commits += 1
        if postsChangeNotifications { notificationCenter.post(name: .EKEventStoreChanged, object: self) }
        if landsThenThrowsOnCommit { throw CalendarEventWriteError.saveFailed("Commit landed before error.") }
    }

    func rollback() { staged = nil; rollbacks += 1 }
    func openInCalendar(_ occurrenceID: String) throws {
        if let openError { throw openError }
        opened.append(occurrenceID)
    }
}
