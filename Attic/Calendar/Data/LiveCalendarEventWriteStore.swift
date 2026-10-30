import AppKit
import EventKit
import Foundation

/// Private transaction store, separate from the page's read store. The second
/// reader sees committed state even while the writer has unsaved changes.
/// Merely constructing this adapter does not create an EKEventStore.
@MainActor
final class LiveCalendarEventWriteStore: CalendarEventWriteStore {
    private lazy var writer = EKEventStore()
    private lazy var reader = EKEventStore()

    var accessState: CalendarAccessState {
        EventKitCalendarEventSource.accessState(for: EKEventStore.authorizationStatus(for: .event))
    }

    func calendars() -> [CalendarWriteCalendar] {
        guard accessState == .granted else { return [] }
        reader.reset()
        return reader.calendars(for: .event).map { calendar in
            CalendarWriteCalendar(id: calendar.calendarIdentifier, title: calendar.title,
                colour: EventKitCalendarEventSource.colour(from: calendar.cgColor),
                sourceID: calendar.source.sourceIdentifier, sourceTitle: calendar.source.title,
                isWritable: calendar.allowsContentModifications && calendar.allowedEntityTypes.contains(.event))
        }
    }

    func event(identifier: String) -> CalendarWriteSnapshot? {
        guard accessState == .granted else { return nil }
        reader.reset()
        return lookup(identifier, in: reader).flatMap(snapshot)
    }

    func stageCreate(_ draft: CalendarEventDraft, marker: String) throws -> CalendarWriteSnapshot {
        try requireLiveWrite()
        writer.reset()
        let event = EKEvent(eventStore: writer)
        try apply(draft, to: event)
        event.url = URL(string: marker)
        try saveStaged(event)
        guard let result = snapshot(event) else { throw CalendarEventWriteError.saveFailed("EventKit did not assign an item identifier.") }
        return result
    }

    func stageEdit(_ previous: CalendarWriteSnapshot, draft: CalendarEventDraft) throws -> CalendarWriteSnapshot {
        try requireLiveWrite()
        writer.reset()
        let event = try editable(previous)
        try apply(draft, to: event)
        try saveStaged(event)
        guard let result = snapshot(event) else { throw CalendarEventWriteError.saveFailed("EventKit did not assign an item identifier.") }
        return result
    }

    func stageDelete(_ previous: CalendarWriteSnapshot) throws {
        try requireLiveWrite()
        writer.reset()
        let event = try editable(previous)
        do { try writer.remove(event, span: .thisEvent, commit: false) }
        catch { throw Self.typed(error) }
    }

    func commit() throws {
        try requireLiveWrite()
        do { try writer.commit() }
        catch { throw Self.typed(error) }
    }

    func rollback() { writer.reset() }

    private func requireLiveWrite() throws {
        // A second safety boundary in addition to the factory's fake. A future
        // test accidentally constructing this adapter still cannot write.
        let environment = AppRuntimeEnvironment()
        guard !environment.isRunningTests && !environment.isUITesting else {
            throw CalendarEventWriteError.saveFailed("Live calendar writes are disabled in tests.")
        }
        guard accessState == .granted else { throw CalendarEventWriteError.accessDenied }
    }

    private func lookup(_ identifier: String, in store: EKEventStore) -> EKEvent? {
        store.event(withIdentifier: identifier) ?? store.calendarItem(withIdentifier: identifier) as? EKEvent
    }

    private func editable(_ previous: CalendarWriteSnapshot) throws -> EKEvent {
        guard let event = lookup(previous.eventIdentifier, in: writer), event.refresh() else {
            throw CalendarEventWriteError.eventMissing
        }
        guard !event.hasRecurrenceRules && !event.isDetached else { throw CalendarEventWriteError.repeatingEvent }
        guard event.calendar.allowsContentModifications else { throw CalendarEventWriteError.calendarReadOnly }
        guard snapshot(event) == previous else { throw CalendarEventWriteError.eventChanged }
        return event
    }

    private func apply(_ draft: CalendarEventDraft, to event: EKEvent) throws {
        guard let calendar = writer.calendar(withIdentifier: draft.calendarID) else { throw CalendarEventWriteError.calendarMissing }
        guard calendar.allowsContentModifications && calendar.allowedEntityTypes.contains(.event) else {
            throw CalendarEventWriteError.calendarReadOnly
        }
        event.calendar = calendar
        event.title = draft.title
        event.timeZone = TimeZone(identifier: draft.timeZoneID)
        event.isAllDay = draft.isAllDay
        event.startDate = draft.start
        event.endDate = draft.end
    }

    private func saveStaged(_ event: EKEvent) throws {
        do { try writer.save(event, span: .thisEvent, commit: false) }
        catch { throw Self.typed(error) }
    }

    private func snapshot(_ event: EKEvent) -> CalendarWriteSnapshot? {
        guard let start = event.startDate, let end = event.endDate,
              let calendar = event.calendar, !event.calendarItemIdentifier.isEmpty else { return nil }
        let zone = event.timeZone ?? .autoupdatingCurrent
        var dates = Calendar(identifier: .gregorian)
        dates.timeZone = zone
        let first = event.isAllDay ? dates.startOfDay(for: start) : start
        let last: Date
        if event.isAllDay {
            let lastDay = dates.startOfDay(for: end.addingTimeInterval(-0.001))
            last = dates.date(byAdding: .day, value: 1, to: lastDay) ?? end
        } else { last = end }
        let draft = CalendarEventDraft(title: event.title ?? "", start: first, end: last,
            isAllDay: event.isAllDay, calendarID: calendar.calendarIdentifier, timeZoneID: zone.identifier)
        // Refuse to destroy metadata added outside Attic. EventKit's revision
        // timestamp is intentionally excluded: commit/sync changes it itself.
        let metadata: [String: Any] = [
            "notes": event.notes ?? "", "location": event.location ?? "",
            "structuredLocation": location(event.structuredLocation),
            "availability": event.availability.rawValue,
            "organizer": event.organizer?.url.absoluteString ?? "",
            "attendees": (event.attendees ?? []).map {
                [$0.url.absoluteString, $0.name ?? "", String($0.participantStatus.rawValue), String($0.participantRole.rawValue)]
            }.sorted { $0.lexicographicallyPrecedes($1) },
            "alarms": (event.alarms ?? []).map { alarm -> [String: Any] in
                ["absolute": alarm.absoluteDate?.timeIntervalSinceReferenceDate ?? 0,
                 "relative": alarm.relativeOffset, "proximity": alarm.proximity.rawValue,
                 "location": location(alarm.structuredLocation)]
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
              let fingerprint = String(data: data, encoding: .utf8) else { return nil }
        let identifier = event.eventIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? event.calendarItemIdentifier
        return CalendarWriteSnapshot(eventIdentifier: identifier, itemIdentifier: event.calendarItemIdentifier,
            marker: event.url?.absoluteString ?? "", draft: draft,
            isRepeating: event.hasRecurrenceRules || event.isDetached, metadata: fingerprint)
    }

    private func location(_ location: EKStructuredLocation?) -> [String: Any] {
        guard let location else { return [:] }
        var result: [String: Any] = ["title": location.title ?? "", "radius": location.radius]
        if let coordinate = location.geoLocation?.coordinate {
            result["latitude"] = coordinate.latitude
            result["longitude"] = coordinate.longitude
        }
        return result
    }

    private static func typed(_ error: Error) -> CalendarEventWriteError {
        let nsError = error as NSError
        if nsError.domain == EKErrorDomain {
            switch nsError.code {
            case EKError.Code.calendarReadOnly.rawValue, EKError.Code.calendarDoesNotAllowEvents.rawValue:
                return .calendarReadOnly
            case EKError.Code.eventStoreNotAuthorized.rawValue: return .accessDenied
            case EKError.Code.noCalendar.rawValue: return .calendarMissing
            default: break
            }
        }
        return .saveFailed(error.localizedDescription)
    }

    func openInCalendar(_ occurrenceID: String) throws {
        let environment = AppRuntimeEnvironment()
        guard !environment.isRunningTests && !environment.isUITesting else { throw CalendarEventWriteError.openFailed }
        guard accessState == .granted else { throw CalendarEventWriteError.accessDenied }
        guard let at = occurrenceID.lastIndex(of: "@"),
              let stamp = occurrenceID[occurrenceID.index(after: at)...].split(separator: "#").first,
              let seconds = Double(stamp),
              seconds.isFinite else { throw CalendarEventWriteError.openFailed }
        let identifier = String(occurrenceID[..<at])
        let start = Date(timeIntervalSinceReferenceDate: seconds)
        reader.reset()
        let predicate = reader.predicateForEvents(withStart: start.addingTimeInterval(-1),
                                                  end: start.addingTimeInterval(1), calendars: nil)
        let candidates = reader.events(matching: predicate).filter {
            ($0.eventIdentifier ?? $0.calendarItemIdentifier) == identifier && $0.startDate == start
        }
        guard let event = candidates.first ?? lookup(identifier, in: reader),
              let url = Self.calendarURL(itemIdentifier: event.calendarItemIdentifier, start: start,
                                        isRepeating: event.hasRecurrenceRules || event.isDetached),
              NSWorkspace.shared.open(url) else { throw CalendarEventWriteError.openFailed }
    }

    /// Calendar's native event-opening URL. Building this URL never opens an
    /// app; the single workspace call above is reached only by an explicit open.
    static func calendarURL(itemIdentifier: String, start: Date, isRepeating: Bool) -> URL? {
        guard !itemIdentifier.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        var components = URLComponents()
        components.scheme = "ical"
        components.host = "ekevent"
        components.path = isRepeating ? "/\(itemIdentifier)" : "/\(formatter.string(from: start))/\(itemIdentifier)"
        components.queryItems = [URLQueryItem(name: "method", value: "show"), URLQueryItem(name: "options", value: "more")]
        return components.url
    }
}
