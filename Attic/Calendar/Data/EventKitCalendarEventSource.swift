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
    func requestFullAccess(_ completion: @escaping @Sendable (Result<Bool, Error>) -> Void)
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

    func requestFullAccess(_ completion: @escaping @Sendable (Result<Bool, Error>) -> Void) {
        store.requestFullAccessToEvents { granted, error in
            if let error { completion(.failure(error)) }
            else { completion(.success(granted)) }
        }
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

/// Async capability kept separate from the shared synchronous source contract.
@MainActor
protocol AsyncCalendarEventReading: AnyObject {
    func loadEvents(in interval: DateInterval) async -> [CalendarEvent]
}

/// Search streams matching batches so an all-date scan never blocks the
/// main actor or queues a long scan ahead of ordinary agenda reads.
@MainActor
protocol AsyncCalendarEventSearching: AnyObject {
    func searchEvents(_ query: String, in interval: DateInterval, around date: Date) -> AsyncStream<[CalendarEvent]>
}

@MainActor
final class EventKitCalendarEventSource: CalendarEventSource, AsyncCalendarEventReading, AsyncCalendarEventSearching {
    /// EventKit matches at most four years per predicate; stay well inside it.
    nonisolated static let maximumFetchSpan: TimeInterval = 3 * 365 * 86_400
    /// Fallback when a calendar reports no colour.
    nonisolated static let fallbackColour = CalendarEventColour(red: 0.56, green: 0.56, blue: 0.58)

    var onChange: (@MainActor () -> Void)?

    private let store: CalendarEventStoring
    private let calendar: Calendar
    private let worker: CalendarEventReadWorker
    private var generation = 0
    private var ranges: [(DateInterval, [CalendarEvent])] = []
    private var pending: [DateInterval: Task<[CalendarEvent], Never>] = [:]
    private let observers: NotificationObserverBag

    init(
        store: CalendarEventStoring = LiveCalendarEventStore(),
        calendar: Calendar = .autoupdatingCurrent,
        notificationCenter: NotificationCenter = .default
    ) {
        self.store = store
        self.calendar = calendar
        self.worker = CalendarEventReadWorker(store: store, calendar: calendar)
        self.observers = NotificationObserverBag(center: notificationCenter)
        // Calendar edits, and a time-zone change (floating and all-day events
        // move with the Mac's zone), both mean the page should read again.
        for name in [Notification.Name.EKEventStoreChanged, .NSSystemTimeZoneDidChange] {
            observers.observe(name) { [weak self] in
                guard let self else { return }
                self.generation += 1
                self.ranges.removeAll()
                self.pending.values.forEach { $0.cancel() }
                self.pending.removeAll()
                self.onChange?()
            }
        }
    }

    var accessState: CalendarAccessState {
        Self.accessState(for: store.authorizationStatus())
    }

    func requestAccess() async -> CalendarAccessState {
        guard store.authorizationStatus() == .notDetermined else { return accessState }
        _ = try? await worker.requestFullAccess()
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

    nonisolated static func accessState(for status: EKAuthorizationStatus) -> CalendarAccessState {
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
    nonisolated static func colour(from cgColor: CGColor?) -> CalendarEventColour {
        guard let cgColor,
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = cgColor.converted(to: sRGB, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3
        else { return fallbackColour }
        func clamp(_ value: CGFloat) -> Double { min(max(Double(value), 0), 1) }
        return CalendarEventColour(red: clamp(components[0]), green: clamp(components[1]), blue: clamp(components[2]))
    }

    /// Stable per occurrence: the event identifier plus the occurrence start.
    nonisolated static func occurrenceID(eventIdentifier: String, start: Date) -> String {
        "\(eventIdentifier)@\(start.timeIntervalSinceReferenceDate)"
    }

    func dayBounds(start: Date, end: Date) -> (start: Date, end: Date) {
        CalendarEventMapper(calendar: calendar).dayBounds(start: start, end: end)
    }

    func event(from occurrence: CalendarStoreOccurrence) -> CalendarEvent {
        CalendarEventMapper(calendar: calendar).event(from: occurrence)
    }

    // MARK: Fetching

    /// The store queries that cover `interval`, each within EventKit's limit.
    /// Padded a day each side so all-day and floating events at the edges are
    /// read before the exact overlap filter.
    nonisolated static func fetchSpans(for interval: DateInterval) -> [DateInterval] {
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

    /// Compatibility for synchronous fixture clients. UI consumers use the
    /// async capability; even compatibility reads keep EK objects on the worker.
    private func fetch(_ interval: DateInterval) -> [CalendarEvent] { worker.eventsSynchronously(in: interval) }

    func loadEvents(in interval: DateInterval) async -> [CalendarEvent] {
        guard accessState == .granted else { return [] }
        if let cached = ranges.first(where: { $0.0 == interval }) { return cached.1 }
        let epoch = generation
        let task: Task<[CalendarEvent], Never>
        if let existing = pending[interval] { task = existing }
        else {
            let worker = worker
            task = Task { await worker.events(in: interval) }
            pending[interval] = task
        }
        let events = await task.value
        guard generation == epoch else { return [] }
        pending[interval] = nil
        guard accessState == .granted else { ranges.removeAll(); return [] }
        ranges.removeAll { $0.0 == interval }
        ranges.append((interval, events))
        if ranges.count > 2 { ranges.removeFirst(ranges.count - 2) }
        return Task.isCancelled ? [] : events
    }

    func searchEvents(_ query: String, in interval: DateInterval, around date: Date) -> AsyncStream<[CalendarEvent]> {
        guard accessState == .granted else { return AsyncStream { $0.finish() } }
        return worker.search(query, in: interval, around: date)
    }

    /// Lists need unique ids; two different occurrences sharing an identifier
    /// and start (rare detached repeats) get a stable suffix in agenda order.
    nonisolated static func uniquingIDs(_ events: [CalendarEvent]) -> [CalendarEvent] {
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

/// Confined serial ownership, including lazy EKEventStore creation, mapping
/// and permission initiation. Only value snapshots cross the queue boundary.
private final class CalendarEventReadWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.taha.Attic.calendar-reads", qos: .userInitiated)
    private let store: CalendarEventStoring
    private let calendar: Calendar
    init(store: CalendarEventStoring, calendar: Calendar) { self.store = store; self.calendar = calendar }

    func requestFullAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in store.requestFullAccess { continuation.resume(with: $0) } }
        }
    }

    func events(in interval: DateInterval) async -> [CalendarEvent] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: read(interval)) }
        }
    }

    func eventsSynchronously(in interval: DateInterval) -> [CalendarEvent] { queue.sync { read(interval) } }

    /// Mutable scan state is confined to `queue`; cancellation alone crosses
    /// queues, through a lock. Each span yields the queue to agenda requests.
    private final class Search: @unchecked Sendable {
        let query: String
        let interval: DateInterval
        let continuation: AsyncStream<[CalendarEvent]>.Continuation
        var spans: [DateInterval] = []
        var index = 0
        var seen = Set<CalendarEvent>()
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        init(query: String, interval: DateInterval, continuation: AsyncStream<[CalendarEvent]>.Continuation) {
            self.query = query; self.interval = interval; self.continuation = continuation
        }
    }

    func search(_ query: String, in interval: DateInterval, around date: Date) -> AsyncStream<[CalendarEvent]> {
        AsyncStream { continuation in
            let scan = Search(query: query, interval: interval, continuation: continuation)
            continuation.onTermination = { _ in scan.cancel() }
            queue.async { [self] in
                // Nearby dates arrive first, with the same complete domain.
                scan.spans = EventKitCalendarEventSource.fetchSpans(for: interval).sorted {
                    abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date))
                }
                continueSearch(scan)
            }
        }
    }

    private func continueSearch(_ scan: Search) {
        queue.async { [self] in
            guard !scan.isCancelled, scan.index < scan.spans.count else { scan.continuation.finish(); return }
            let span = scan.spans[scan.index]
            scan.index += 1
            var matches: [CalendarEvent] = []
            for occurrence in store.occurrences(from: span.start, to: span.end) {
                let event = CalendarEventMapper(calendar: calendar).event(from: occurrence)
                guard event.overlaps(scan.interval), event.matches(scan.query), scan.seen.insert(event).inserted else { continue }
                matches.append(event)
            }
            if !matches.isEmpty, !scan.isCancelled { scan.continuation.yield(matches) }
            continueSearch(scan)
        }
    }

    private func read(_ interval: DateInterval) -> [CalendarEvent] {
        var seen = Set<CalendarEvent>()
        var events: [CalendarEvent] = []
        for span in EventKitCalendarEventSource.fetchSpans(for: interval) {
            for occurrence in store.occurrences(from: span.start, to: span.end) {
                let event = CalendarEventMapper(calendar: calendar).event(from: occurrence)
                // An occurrence crossing a span boundary comes back twice.
                guard event.overlaps(interval), seen.insert(event).inserted else { continue }
                events.append(event)
            }
        }
        return EventKitCalendarEventSource.uniquingIDs(events.sortedForAgenda())
    }

}

private struct CalendarEventMapper {
    let calendar: Calendar
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
            id: EventKitCalendarEventSource.occurrenceID(eventIdentifier: identifier, start: occurrence.start),
            title: occurrence.title ?? "",
            start: bounds.0,
            end: bounds.1,
            isAllDay: occurrence.isAllDay,
            location: location?.isEmpty == false ? location : nil,
            calendarTitle: occurrence.calendarTitle,
            colour: EventKitCalendarEventSource.colour(from: occurrence.calendarColour)
        )
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
