import SwiftData
import SwiftUI

// This stage links the actual shared schema into the new local phone target.
// The synthetic library and interactive shell are introduced at the next gate.
@main
struct AtticMobileApp: App {
    private let database: Result<ModelContainer, Error> = Result {
        try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
    }

    var body: some Scene {
        WindowGroup {
            switch database {
            case .success(let container):
                Text("Attic").modelContainer(container)
            case .failure(let error):
                ContentUnavailableView("Library unavailable", systemImage: "exclamationmark.triangle", description: Text(error.localizedDescription))
            }
        }
    }
}
