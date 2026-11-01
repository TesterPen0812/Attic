import Foundation

enum CalendarEventWriters {
    /// The composer retains its writer. Tests get memory + fake; live file
    /// initialization and EventKit transactions happen on the writer worker.
    @MainActor
    static func makeDefault(undoRoute: UndoRoute,
                            environment: AppRuntimeEnvironment = AppRuntimeEnvironment()) throws -> CalendarEventWriter {
        let runtime = AppRuntimeEnvironment()
        if environment.isRunningTests || environment.isUITesting || runtime.isRunningTests || runtime.isUITesting {
            return EventKitCalendarEventWriter(store: FakeCalendarEventWriteStore(),
                                               record: try CalendarOwnershipRecord(), undoRoute: undoRoute)
        }
        return BackgroundCalendarEventWriter(undoRoute: undoRoute) {
            do {
                let support = try environment.applicationSupportURL ?? FileManager.default.url(
                    for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let directory = support.appendingPathComponent(environment.bundleIdentifier ?? "Attic", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let record = try CalendarOwnershipRecord(fileURL: directory.appendingPathComponent("CalendarOwnership-v1.json"))
                return CalendarEventTransactions(store: LiveCalendarEventWriteStore(), record: record)
            } catch let error as CalendarEventWriteError { throw error }
            catch { throw CalendarEventWriteError.recordFailed(error.localizedDescription) }
        }
    }
}
