import CoreGraphics
import EventKit
import Foundation

// The EventKit source behind `CalendarEventSource`. Read-only: it asks for
// access, reads occurrences and listens for changes. Nothing here saves or
// removes anything in a calendar.

/// One occurrence as the event store reports it, before Attic maps it.
struct CalendarStoreOccurrence {
    /// `EKEvent.eventIdentifier`; nil falls back to `itemIdentifier`.
    var eventIdentifier: String?
    var itemIdentifier: String
    var title: String?
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
    var calendarTitle: String
    var calendarColour: CGColor?
    /// Nil for a floating event, whose wall-clock time follows the Mac's zone.
    var timeZone: TimeZone?
}

/// The seam around `EKEventStore`, so tests never touch real EventKit.
protocol CalendarEventStoring: AnyObject {
    func authorizationStatus() -> EKAuthorizationStatus
    /// Shows the system prompt; only called while the status is not determined.
    func requestFullAccess() async throws -> Bool
    /// Occurrences overlapping `start..<end`, repeats expanded. Spans longer than
    /// EventKit's four-year limit are split by the caller.
    func occurrences(from start: Date, to end: Date) -> [CalendarStoreOccurrence]
}

/// The real store. `EKEventStore` is created only when first needed.
final class LiveCalendarEventStore: CalendarEventStoring {
    private lazy var store = EKEventStore()

    func authorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    func requestFullAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    func occurrences(from start: Date, to end: Date) -> [CalendarStoreOccurrence] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).compactMap { event in
            guard let startDate = event.startDate, let endDate = event.endDate else { return nil }
            let calendar: EKCalendar? = event.calendar
            return CalendarStoreOccurrence(
                eventIdentifier: event.eventIdentifier,
                itemIdentifier: event.calendarItemIdentifier,
                title: event.title,
                start: startDate,
                end: endDate,
                isAllDay: event.isAllDay,
                location: event.location ?? event.structuredLocation?.title,
                calendarTitle: calendar?.title ?? "",
                calendarColour: calendar?.cgColor,
                timeZone: event.timeZone
            )
        }
    }
}

@MainActor
final class EventKitCalendarEventSource: CalendarEventSource {
    /// EventKit matches at most four years per predicate; stay well inside it.
    static let maximumFetchSpan: TimeInterval = 3 * 365 * 86_400
    /// Fallback when a calendar reports no colour.
    static let fallbackColour = CalendarEventColour(red: 0.56, green: 0.56, blue: 0.58)

    var onChange: (@MainActor () -> Void)?

    private let store: CalendarEventStoring
    private let calendar: Calendar
    private let observers: NotificationObserverBag

    init(
        store: CalendarEventStoring = LiveCalendarEventStore(),
        calendar: Calendar = .autoupdatingCurrent,
        notificationCenter: NotificationCenter = .default
    ) {
        self.store = store
        self.calendar = calendar
        self.observers = NotificationObserverBag(center: notificationCenter)
        // Calendar edits, and a time-zone change (floating and all-day events
        // move with the Mac's zone), both mean the page should read again.
        for name in [Notification.Name.EKEventStoreChanged, .NSSystemTimeZoneDidChange] {
            observers.observe(name) { [weak self] in self?.onChange?() }
        }
    }

    var accessState: CalendarAccessState {
        Self.accessState(for: store.authorizationStatus())
    }

    func requestAccess() async -> CalendarAccessState {
        guard store.authorizationStatus() == .notDetermined else { return accessState }
        _ = try? await store.requestFullAccess()
        return accessState
    }

    func events(in interval: DateInterval) -> [CalendarEvent] {
        guard accessState == .granted else { return [] }
        return fetch(interval)
    }

    func search(_ text: String, in interval: DateInterval) -> [CalendarEvent] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return events(in: interval).filter { $0.matches(query) }
    }

    // MARK: Mapping

    static func accessState(for status: EKAuthorizationStatus) -> CalendarAccessState {
        switch status {
        // The deprecated `.authorized` shares `.fullAccess`'s raw value.
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        // Write-only access can't read events, so for this page it is a denial.
        case .denied, .writeOnly: .denied
        @unknown default: .denied
        }
    }

    /// The calendar colour as sRGB components clamped to 0...1.
    static func colour(from cgColor: CGColor?) -> CalendarEventColour {
        guard let cgColor,
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = cgColor.converted(to: sRGB, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3
        else { return fallbackColour }
        func clamp(_ value: CGFloat) -> Double { min(max(Double(value), 0), 1) }
        return CalendarEventColour(red: clamp(components[0]), green: clamp(components[1]), blue: clamp(components[2]))
    }

    /// Stable per occurrence: the event identifier plus the occurrence start.
    static func occurrenceID(eventIdentifier: String, start: Date) -> String {
        "\(eventIdentifier)@\(start.timeIntervalSinceReferenceDate)"
    }

    /// An all-day occurrence covers whole local days: from the start day's
    /// midnight to the midnight after its last day. EventKit reports the end as
    /// the next midnight or as 23:59:59 on the last day; both map the same.
    func dayBounds(start: Date, end: Date) -> (start: Date, end: Date) {
        let firstDay = calendar.startOfDay(for: start)
        let lastMoment = end > start ? end.addingTimeInterval(-0.001) : start
        let lastDay = max(firstDay, calendar.startOfDay(for: lastMoment))
        let after = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay.addingTimeInterval(86_400)
        return (firstDay, after)
    }

    func event(from occurrence: CalendarStoreOccurrence) -> CalendarEvent {
        // Floating events (no time zone) keep EventKit's dates, which already
        // place the wall-clock time in the Mac's current zone.
        let bounds = occurrence.isAllDay ? dayBounds(start: occurrence.start, end: occurrence.end) : (occurrence.start, max(occurrence.end, occurrence.start))
        let identifier = occurrence.eventIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? occurrence.itemIdentifier
        let location = occurrence.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CalendarEvent(
            id: Self.occurrenceID(eventIdentifier: identifier, start: occurrence.start),
            title: occurrence.title ?? "",
            start: bounds.0,
            end: bounds.1,
            isAllDay: occurrence.isAllDay,
            location: location?.isEmpty == false ? location : nil,
            calendarTitle: occurrence.calendarTitle,
            colour: Self.colour(from: occurrence.calendarColour)
        )
    }

    // MARK: Fetching

    /// The store queries that cover `interval`, each within EventKit's limit.
    /// Padded a day each side so all-day and floating events at the edges are
    /// read before the exact overlap filter.
    static func fetchSpans(for interval: DateInterval) -> [DateInterval] {
        let start = interval.start.addingTimeInterval(-86_400)
        let end = interval.end.addingTimeInterval(86_400)
        var spans: [DateInterval] = []
        var cursor = start
        while cursor < end {
            let next = min(cursor.addingTimeInterval(maximumFetchSpan), end)
            spans.append(DateInterval(start: cursor, end: next))
            cursor = next
        }
        return spans
    }

    private func fetch(_ interval: DateInterval) -> [CalendarEvent] {
        var seen = Set<CalendarEvent>()
        var events: [CalendarEvent] = []
        for span in Self.fetchSpans(for: interval) {
            for occurrence in store.occurrences(from: span.start, to: span.end) {
                let event = event(from: occurrence)
                // An occurrence crossing a span boundary comes back twice.
                guard event.overlaps(interval), seen.insert(event).inserted else { continue }
                events.append(event)
            }
        }
        return Self.uniquingIDs(events.sortedForAgenda())
    }

    /// Lists need unique ids; two different occurrences sharing an identifier
    /// and start (rare detached repeats) get a stable suffix in agenda order.
    static func uniquingIDs(_ events: [CalendarEvent]) -> [CalendarEvent] {
        var counts: [String: Int] = [:]
        return events.map { event in
            let count = counts[event.id, default: 0] + 1
            counts[event.id] = count
            guard count > 1 else { return event }
            var copy = event
            copy.id = "\(event.id)#\(count)"
            return copy
        }
    }
}

/// Holds block observers and removes them when the source goes away.
private final class NotificationObserverBag {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter) {
        self.center = center
    }

    func observe(_ name: Notification.Name, perform action: @escaping @MainActor () -> Void) {
        tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        })
    }

    deinit {
        tokens.forEach(center.removeObserver)
    }
}
