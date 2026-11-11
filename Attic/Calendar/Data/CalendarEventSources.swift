import Foundation

/// Where the Calendar page gets its events.
enum CalendarEventSources {
    /// EventKit in the app; the stub under the unit-test host and
    /// `ATTIC_UI_TESTING`, so tests never meet a permission prompt.
    @MainActor
    static func makeDefault(environment: AppRuntimeEnvironment = AppRuntimeEnvironment()) -> CalendarEventSource {
        if environment.isUITesting, environment.environment["ATTIC_PERF_PROFILE"] == "clicklag4" {
            // An isolated, read-only busy week; no EventKit access or real writes.
            let calendar = Calendar.current
            let monday = calendar.dateInterval(of: .weekOfYear, for: Date())!.start
            let events: [CalendarEvent] = (0..<7).flatMap { day -> [CalendarEvent] in
                (0..<8).map { slot in
                    let start = calendar.date(byAdding: .hour, value: day * 24 + slot + 8, to: monday)!
                    return CalendarEvent(
                        id: "clicklag4-\(day)-\(slot)", title: "Project session \(day + 1).\(slot + 1)",
                        start: start, end: start.addingTimeInterval(45 * 60), isAllDay: false,
                        location: "Room \(slot + 1)", calendarTitle: "Demo calendar",
                        colour: CalendarEventColour(red: 0.35, green: 0.55, blue: 0.85)
                    )
                }
            }
            return CalendarEventSourceStub(events: events)
        }
        #if DEBUG
        if UITestingCalendar.isOn { return UITestingCalendarSource() }
        #endif
        if environment.isRunningTests || environment.isUITesting {
            return CalendarEventSourceStub()
        }
        return EventKitCalendarEventSource()
    }
}

/// A source-independent identity and ordering policy for displayed occurrences.
/// Re-apply it after each streamed batch, so a later nearby-first batch can
/// change the row order without keeping duplicate SwiftUI row identities.
enum CalendarEventPresentation {
    static func orderedUnique(_ events: [CalendarEvent]) -> [CalendarEvent] {
        var counts: [String: Int] = [:]
        return events.sortedForAgenda().map { event in
            let count = counts[event.id, default: 0] + 1
            counts[event.id] = count
            guard count > 1 else { return event }
            var copy = event
            copy.id = "\(event.id)#\(count)"
            return copy
        }
    }
}
