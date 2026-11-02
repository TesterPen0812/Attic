import Foundation
import SwiftData

enum AtticCloudKitEnvironment: String {
    case development = "Development"
    case production = "Production"
}

enum PersistenceController {
    private static let cloudKitEnvironmentInfoKey = "AtticCloudKitEnvironment"

    private enum Scope: Equatable { case shared, deviceLocal }
    private typealias Entry = (model: any PersistentModel.Type, scope: Scope)

    // Keep the existing Mac registration order. Shared means eligible for future
    // explicit records, not that every row/field is exportable or mirroring is on.
    private static var registry: [Entry] {
        var entries: [Entry] = [
            (TaskItem.self, .shared), (NoteItem.self, .shared), (NoteAttachment.self, .shared)
        ]
        #if os(macOS)
        entries += [
            (CanvasBoardItem.self, .deviceLocal), (CanvasStrokeItem.self, .deviceLocal),
            (CanvasImageItem.self, .deviceLocal), (CanvasSemanticObjectItem.self, .deviceLocal)
        ]
        #endif
        entries += [
            (DrawCanvasRecord.self, .shared), (DrawObjectRecord.self, .shared),
            (DrawPayloadRecord.self, .shared), (ItemLink.self, .shared),
            (NoteVersion.self, .shared), (NotePendingEdit.self, .shared)
        ]
        #if os(macOS)
        entries.append((StoreMaintenance.self, .deviceLocal))
        #endif
        entries.append((TagColour.self, .shared))
        #if os(macOS)
        entries.append((OperationReceipt.self, .deviceLocal))
        #endif
        entries += [(TaskNoteAssociation.self, .shared), (TaskDeletionPreservation.self, .shared)]
        #if os(macOS)
        entries.append((TaskAttachmentMigrationRecord.self, .deviceLocal))
        #endif
        return entries
    }

    static var appModelTypes: [any PersistentModel.Type] { registry.map { $0.model } }
    static var syncedModelTypes: [any PersistentModel.Type] {
        registry.filter { $0.scope == .shared }.map { $0.model }
    }
    static var deviceLocalModelTypes: [any PersistentModel.Type] {
        registry.filter { $0.scope == .deviceLocal }.map { $0.model }
    }

    static func makeConfiguration(
        inMemory: Bool = false,
        cloudSyncEnabled _: Bool = false,
        environment: AtticCloudKitEnvironment? = nil,
        storeDirectory: URL? = nil
    ) -> ModelConfiguration {
        // Keep the legacy argument label for existing callers. SwiftData is always
        // local; explicit-record sync must never enable framework mirroring.
        // `storeDirectory` relocates the store (tests open copies of
        // fixture stores through this exact path); nil is the app's default
        // Application Support location.
        let defaultConfiguration = if let storeDirectory, !inMemory {
            ModelConfiguration(
                url: storeDirectory.appendingPathComponent("default.store"),
                cloudKitDatabase: .none
            )
        } else {
            ModelConfiguration(
                isStoredInMemoryOnly: inMemory,
                cloudKitDatabase: .none
            )
        }
        let resolvedEnvironment = environment ?? currentCloudKitEnvironment
        guard !inMemory,
              resolvedEnvironment == .development else {
            return defaultConfiguration
        }

        // Keep the existing Development and Production store locations disjoint.
        let developmentURL = defaultConfiguration.url
            .deletingLastPathComponent()
            .appendingPathComponent("development.store")
        return ModelConfiguration(
            "development",
            url: developmentURL,
            cloudKitDatabase: .none
        )
    }

    static func makeContainer(
        inMemory: Bool = false,
        cloudSyncEnabled: Bool = false,
        storeDirectory: URL? = nil
    ) throws -> ModelContainer {
        let configuration = makeConfiguration(
            inMemory: inMemory,
            cloudSyncEnabled: cloudSyncEnabled,
            storeDirectory: storeDirectory
        )
        #if os(macOS)
        let lease = configuration.isStoredInMemoryOnly ? nil : try WorkspaceWriterLease.acquire(storeURL: configuration.url)
        #endif
        let container = try ModelContainer(for: Schema(appModelTypes), configurations: configuration)
        #if os(macOS)
        if let lease { WorkspaceWriterLease.attach(lease, to: container) }
        _ = try OldNotesPurge.run(in: container)
        #endif
        return container
    }

    #if os(macOS)
    /// A durable, CloudKit-free store used only by controlled UI tests that
    /// need to terminate and relaunch the app. Its path is disjoint from every
    /// normal Attic store, and reset removes only this store family.
    static func makeCanvasUITestContainer(
        reset: Bool,
        baseDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> ModelContainer {
        let root = baseDirectory ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let bundleComponent = (Bundle.main.bundleIdentifier ?? "unknown-bundle")
            .replacingOccurrences(of: "/", with: "-")
        let directory = root
            .appendingPathComponent("AtticCanvasUITests", isDirectory: true)
            .appendingPathComponent(bundleComponent, isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let storeURL = directory.appendingPathComponent("canvas.store")
        if reset {
            try removeStoreFamily(at: storeURL, fileManager: fileManager)
        }

        let configuration = ModelConfiguration(
            "canvas-ui-testing",
            url: storeURL,
            cloudKitDatabase: .none
        )
        let lease = configuration.isStoredInMemoryOnly ? nil : try WorkspaceWriterLease.acquire(storeURL: configuration.url)
        let container = try ModelContainer(for: Schema(appModelTypes), configurations: configuration)
        if let lease { WorkspaceWriterLease.attach(lease, to: container) }
        _ = try OldNotesPurge.run(in: container)
        return container
    }
    #endif

    static var currentCloudKitEnvironment: AtticCloudKitEnvironment {
        if let rawValue = Bundle.main.object(
            forInfoDictionaryKey: cloudKitEnvironmentInfoKey
        ) as? String,
           let environment = AtticCloudKitEnvironment(rawValue: rawValue) {
            return environment
        }

        #if DEBUG
        return .development
        #else
        return .production
        #endif
    }

    #if os(macOS)
    private static func removeStoreFamily(
        at storeURL: URL,
        fileManager: FileManager
    ) throws {
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: storeURL.path + suffix)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            try fileManager.removeItem(at: url)
        }
    }
    #endif
}
