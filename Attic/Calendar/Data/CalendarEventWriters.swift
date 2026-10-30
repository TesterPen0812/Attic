import Foundation

enum CalendarEventWriters {
    /// No UI is wired yet. Keep the returned engine with the Calendar page's
    /// state when wave 3 connects its composer. Tests always get memory + fake.
    @MainActor
    static func makeDefault(undoRoute: UndoRoute,
                            environment: AppRuntimeEnvironment = AppRuntimeEnvironment()) throws -> CalendarEventWriter {
        let runtime = AppRuntimeEnvironment()
        if environment.isRunningTests || environment.isUITesting || runtime.isRunningTests || runtime.isUITesting {
            return EventKitCalendarEventWriter(store: FakeCalendarEventWriteStore(),
                                               record: try CalendarOwnershipRecord(), undoRoute: undoRoute)
        }
        do {
            let support = try environment.applicationSupportURL ?? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = support.appendingPathComponent(environment.bundleIdentifier ?? "Attic", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let record = try CalendarOwnershipRecord(fileURL: directory.appendingPathComponent("CalendarOwnership-v1.json"))
            return EventKitCalendarEventWriter(store: LiveCalendarEventWriteStore(), record: record, undoRoute: undoRoute)
        } catch let error as CalendarEventWriteError { throw error }
        catch { throw CalendarEventWriteError.recordFailed(error.localizedDescription) }
    }
}
