import CloudKit
import Combine
import Foundation
import SwiftData

enum ICloudAvailability: Equatable {
    case checking
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    case unavailable(String)

    var title: String {
        switch self {
        case .checking: "Checking iCloud"
        case .available: "iCloud available"
        case .noAccount: "Sign in to iCloud to sync"
        case .restricted: "iCloud access is restricted"
        case .temporarilyUnavailable: "iCloud is temporarily unavailable"
        case .unavailable: "Unable to check iCloud"
        }
    }

    var detail: String {
        switch self {
        case .available:
            "Changes sync automatically across your devices."
        case .checking:
            "Your local task cache remains available."
        case .noAccount, .restricted, .temporarilyUnavailable:
            "Changes stay on this device and sync when iCloud is available."
        case let .unavailable(message):
            message
        }
    }
}

@MainActor
final class MobileAppModel: ObservableObject {
    @Published private(set) var store: TaskStore?
    @Published private(set) var noteStore: NoteStore?
    @Published private(set) var canvasStore: CanvasStore?
    @Published private(set) var canvasSession: CanvasSession?
    @Published private(set) var startupError: String?
    @Published private(set) var iCloudAvailability: ICloudAvailability = .checking

    private var container: ModelContainer?
    private var shouldCheckICloudStatus = true
    private var accountChangeObservation: NSObjectProtocol?

    init() {
        loadStore()
        accountChangeObservation = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshICloudAvailability()
            }
        }
    }

    deinit {
        if let accountChangeObservation {
            NotificationCenter.default.removeObserver(accountChangeObservation)
        }
    }

    func loadStore() {
        do {
            let environment = ProcessInfo.processInfo.environment
            let isRunningTests = environment["ATTIC_TESTING"] == "1"
                || environment["XCTestConfigurationFilePath"] != nil
                || environment["XCTestBundlePath"] != nil
            let usesCanvasUITestPersistence = isRunningTests
                && environment["ATTIC_UI_TEST_CANVAS_PERSISTENCE"] == "1"
            shouldCheckICloudStatus = !isRunningTests
            #if DEBUG
            if !isRunningTests {
                try PersistenceController.initializeCloudKitDevelopmentSchemaIfNeeded()
            }
            #endif

            let container: ModelContainer
            if usesCanvasUITestPersistence {
                container = try PersistenceController.makeCanvasUITestContainer(
                    reset: environment["ATTIC_UI_TEST_CANVAS_RESET"] == "1"
                )
            } else {
                container = try PersistenceController.makeContainer(
                    inMemory: isRunningTests
                )
            }

            let store = TaskStore(container: container)
            let noteStore = NoteStore(container: container)
            let canvasStore = CanvasStore(container: container)
            let canvasSession = CanvasSession(store: canvasStore)

            self.container = container
            self.store = store
            self.noteStore = noteStore
            self.canvasStore = canvasStore
            self.canvasSession = canvasSession
            startupError = nil
            Task { await refresh() }
        } catch {
            container = nil
            store = nil
            noteStore = nil
            canvasStore = nil
            canvasSession = nil
            startupError = error.localizedDescription
        }
    }

    func refresh() async {
        store?.refresh()
        noteStore?.refresh()
        canvasStore?.refresh()
        purgeCompletedBeforeToday()
        await refreshICloudAvailability()
    }

    private func refreshICloudAvailability() async {
        guard shouldCheckICloudStatus else { return }

        do {
            let status = try await CKContainer(
                identifier: PersistenceController.cloudKitContainerIdentifier
            ).accountStatus()
            iCloudAvailability = switch status {
            case .available: .available
            case .noAccount: .noAccount
            case .restricted: .restricted
            case .temporarilyUnavailable: .temporarilyUnavailable
            case .couldNotDetermine: .unavailable("The account status could not be determined.")
            @unknown default: .unavailable("The account returned an unknown status.")
            }
        } catch {
            iCloudAvailability = .unavailable(error.localizedDescription)
        }
    }

    private func purgeCompletedBeforeToday() {
        guard let store else { return }
        let startOfToday = Calendar.autoupdatingCurrent.startOfDay(for: Date())
        store.purgeCompleted(before: startOfToday)
    }
}
