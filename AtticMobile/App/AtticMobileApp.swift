import SwiftData
import SwiftUI

@main
struct AtticMobileApp: App {
    // The iPhone owns its own on-disk SwiftData store. CloudKit mirroring is disabled.
    private let database: Result<ModelContainer, Error> = Result {
        let container = try PersistenceController.makeContainer(inMemory: false, cloudSyncEnabled: false)
        try PhoneSampleSeed.installIfNeeded(container: container, enabled: Self.isOvernightSimulator)
        return container
    }

    private static var isOvernightSimulator: Bool {
        #if targetEnvironment(simulator)
        let environment = ProcessInfo.processInfo.environment
        return environment["SIMULATOR_UDID"]?.uppercased() == "AA9DF4DC-8969-417C-BF40-F0C7C57F9B46"
            && environment["ATTIC_TESTING"] != "1"
        #else
        return false
        #endif
    }

    var body: some Scene {
        WindowGroup {
            switch database {
            case .success(let container):
                PhoneShell(container: container, syntheticCalendar: Self.isOvernightSimulator)
                    .modelContainer(container)
            case .failure(let error):
                ContentUnavailableView("Library unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text(error.localizedDescription))
            }
        }
    }
}
