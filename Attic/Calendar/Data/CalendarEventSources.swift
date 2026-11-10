import Foundation

/// Where the Calendar page gets its events.
enum CalendarEventSources {
    /// EventKit in the app; the stub under the unit-test host and
    /// `ATTIC_UI_TESTING`, so tests never meet a permission prompt.
    @MainActor
    static func makeDefault(environment: AppRuntimeEnvironment = AppRuntimeEnvironment()) -> CalendarEventSource {
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
