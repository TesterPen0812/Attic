import EventKit
import Foundation

#if DEBUG
/// UI testing only (`ATTIC_UI_TEST_CHAT` with `calendar`): one fake calendar
/// that the agent's Calendar writer writes into and the Calendar page reads
/// from, so a watched event can be seen landing. Nothing here reaches
/// EventKit or the owner's calendars.
@MainActor
enum UITestingCalendar {
    /// Set before the writers and the page's source are made.
    static var isOn = false
    static let calendar = CalendarWriteCalendar(id: "personal", title: "Personal",
                                                colour: CalendarEventColour(red: 0.35, green: 0.55, blue: 0.95),
                                                sourceID: "local", sourceTitle: "On My Mac", isWritable: true)

    static let store: FakeCalendarEventWriteStore = {
        let store = FakeCalendarEventWriteStore()
        store.availableCalendars = [calendar]
        store.postsChangeNotifications = true
        return store
    }()

    /// Events already there: the design's seminar, on the coming Friday.
    static var seeded: [CalendarEvent] = []

    static func seed(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
        guard let friday = calendar.nextDate(after: now, matching: DateComponents(weekday: 6), matchingPolicy: .nextTime) else { return }
        var parts = calendar.dateComponents([.year, .month, .day], from: friday)
        parts.hour = 11
        guard let start = calendar.date(from: parts) else { return }
        seeded = [CalendarEvent(id: "seminar@\(start.timeIntervalSinceReferenceDate)", title: "Seminar: Discrete Maths",
                                start: start, end: start.addingTimeInterval(3600), isAllDay: false, location: "B2.04",
                                calendarTitle: "Uni", colour: CalendarEventColour(red: 0.95, green: 0.6, blue: 0.2))]
    }
}

/// The page's view of the UI-testing calendar: the seeded events and every
/// event the writer has committed.
@MainActor
final class UITestingCalendarSource: CalendarEventSource {
    var accessState: CalendarAccessState = .granted
    var onChange: (@MainActor () -> Void)?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: UITestingCalendar.store,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    func requestAccess() async -> CalendarAccessState { accessState }

    func events(in interval: DateInterval) -> [CalendarEvent] {
        let written = UITestingCalendar.store.events.values.map { snapshot in
            CalendarEvent(id: snapshot.occurrenceID, title: snapshot.draft.title, start: snapshot.draft.start,
                          end: snapshot.draft.end, isAllDay: snapshot.draft.isAllDay, location: nil,
                          calendarTitle: UITestingCalendar.calendar.title, colour: UITestingCalendar.calendar.colour)
        }
        return (UITestingCalendar.seeded + written).filter { $0.overlaps(interval) }.sortedForAgenda()
    }

    func search(_ text: String, in interval: DateInterval) -> [CalendarEvent] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return events(in: interval).filter { $0.matches(query) }
    }
}
#endif
