import Foundation

/// Where the Calendar page gets its events.
enum CalendarEventSources {
    /// EventKit in the app; the stub under the unit-test host and
    /// `ATTIC_UI_TESTING`, so tests never meet a permission prompt.
    @MainActor
    static func makeDefault(environment: AppRuntimeEnvironment = AppRuntimeEnvironment()) -> CalendarEventSource {
        if environment.isRunningTests || environment.isUITesting {
            return CalendarEventSourceStub()
        }
        return EventKitCalendarEventSource()
    }
}
