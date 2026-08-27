import Combine
import CoreData
import Foundation
import SwiftData

private enum CanvasReplicaMutationError: LocalizedError {
    case missingStroke(UUID)
    case mutationVersionExhausted(UUID)
    case generationExhausted

    var errorDescription: String? {
        switch self {
        case let .missingStroke(id):
            "The canvas stroke replicas for \(id.uuidString) could not be loaded safely."
        case let .mutationVersionExhausted(id):
            "The canvas stroke \(id.uuidString) cannot be changed because its mutation version is exhausted."
        case .generationExhausted:
            "The canvas cannot be cleared because its generation is exhausted."
        }
    }
}

private struct CanvasStrokeCacheKey: Hashable {
    let id: UUID
    let payloadVersion: Int
    let payload: Data
    let boardGeneration: Int64
    let mutationVersion: Int64
    let createdAt: Date
    let updatedAt: Date
}

@MainActor
final class CanvasStore: ObservableObject {
    @Published private(set) var strokes: [CanvasStroke] = []
    @Published private(set) var boardGeneration: Int64 = 0
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var revision: UInt64 = 0
    @Published private(set) var cloudSyncStatus = CloudSyncStatus()

    private let container: ModelContainer
    private var context: ModelContext
    private let now: () -> Date
    private let persist: (ModelContext) throws -> Void
    private let decodeStroke: (Data, Int) throws -> CanvasStrokeGeometry
    private var visibleStrokeCache: [CanvasStrokeCacheKey: CanvasStroke] = [:]
    private var remoteChangeObservation: AnyCancellable?
    private var cloudKitEventObservation: AnyCancellable?
    private var cloudImportRefreshTask: Task<Void, Never>?
    private var cloudSyncProtection = CloudSyncProtectionState()
#if os(macOS)
    private var exportActivityToken: NSObjectProtocol?
    private var importActivityToken: NSObjectProtocol?
    private var exportActivityTimeoutTask: Task<Void, Never>?
    private var importActivityTimeoutTask: Task<Void, Never>?
    private static let cloudSyncActivityTimeout: Duration = .seconds(120)
#endif

    init(
        container: ModelContainer,
        now: @escaping () -> Date = Date.init,
        persist: @escaping (ModelContext) throws -> Void = { try $0.save() },
        decodeStroke: @escaping (Data, Int) throws -> CanvasStrokeGeometry = { data, version in
            try CanvasStrokeCodec.decode(data, expectedVersion: version)
        }
    ) {
        self.container = container
        context = ModelContext(container)
        self.now = now
        self.persist = persist
        self.decodeStroke = decodeStroke
        refresh()
        observeRemoteChanges()
        observeCloudKitEvents()
    }

    @discardableResult
    func addStroke(
        color: CanvasInkColor,
        width: Double,
        points: [CanvasPoint],
        id: UUID = UUID()
    ) -> CanvasStroke? {
        let payload: Data
        do {
            payload = try CanvasStrokeCodec.encode(
                color: color,
                width: width,
                points: points
            )
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }

        let timestamp = now()
        do {
            let replicas = try storedStrokeReplicas(matching: [id])[id] ?? []
            if replicas.isEmpty {
                context.insert(CanvasStrokeItem(
                    id: id,
                    payloadVersion: CanvasStrokeCodec.currentVersion,
                    payload: payload,
                    boardGeneration: boardGeneration,
                    mutationVersion: 1,
                    tombstoned: false,
                    createdAt: timestamp,
                    updatedAt: timestamp
                ))
            } else {
                let winner = try Self.winningReplica(in: replicas)
                let nextVersion = try Self.nextMutationVersion(
                    after: replicas.map(\.mutationVersion).max() ?? 0,
                    strokeID: id
                )
                for replica in replicas {
                    replica.payloadVersion = CanvasStrokeCodec.currentVersion
                    replica.payload = payload
                    replica.boardGeneration = boardGeneration
                    replica.mutationVersion = nextVersion
                    replica.tombstoned = false
                    replica.createdAt = winner.createdAt
                    replica.updatedAt = timestamp
                    replica.deletedAt = nil
                }
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }

        guard save() else { return nil }
        return strokes.first { $0.id == id }
    }

    @discardableResult
    func setDeleted(
        _ deleted: Bool,
        strokeIDs: Set<UUID>
    ) -> Bool {
        guard !strokeIDs.isEmpty else { return true }

        let grouped: [UUID: [CanvasStrokeItem]]
        do {
            grouped = try storedStrokeReplicas(matching: strokeIDs)
            for id in strokeIDs where grouped[id]?.isEmpty != false {
                throw CanvasReplicaMutationError.missingStroke(id)
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }

        let timestamp = now()
        do {
            var mutations: [
                (
                    replicas: [CanvasStrokeItem],
                    winner: CanvasStrokeItem,
                    nextVersion: Int64
                )
            ] = []
            mutations.reserveCapacity(strokeIDs.count)

            for id in strokeIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                let replicas = grouped[id] ?? []
                let winner = try Self.winningReplica(in: replicas)
                let nextVersion = try Self.nextMutationVersion(
                    after: replicas.map(\.mutationVersion).max() ?? 0,
                    strokeID: id
                )
                mutations.append((replicas, winner, nextVersion))
            }

            for mutation in mutations {
                for replica in mutation.replicas {
                    replica.payloadVersion = mutation.winner.payloadVersion
                    replica.payload = mutation.winner.payload
                    replica.boardGeneration = deleted
                        ? mutation.winner.boardGeneration
                        : boardGeneration
                    replica.mutationVersion = mutation.nextVersion
                    replica.tombstoned = deleted
                    replica.createdAt = mutation.winner.createdAt
                    replica.updatedAt = timestamp
                    replica.deletedAt = deleted ? timestamp : nil
                }
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }

        return save()
    }

    @discardableResult
    func restore(_ snapshots: [CanvasStroke]) -> Bool {
        guard !snapshots.isEmpty else { return true }

        let uniqueSnapshots = Dictionary(
            snapshots.map { ($0.id, $0) },
            uniquingKeysWith: { existing, candidate in
                Self.preferredSnapshot(candidate, over: existing)
                    ? candidate
                    : existing
            }
        )
        let ids = Set(uniqueSnapshots.keys)

        let grouped: [UUID: [CanvasStrokeItem]]
        do {
            grouped = try storedStrokeReplicas(matching: ids)
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }

        struct PreparedRestore {
            let snapshot: CanvasStroke
            let payload: Data
            let replicas: [CanvasStrokeItem]
            let nextVersion: Int64
        }

        var prepared: [PreparedRestore] = []
        do {
            for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let snapshot = uniqueSnapshots[id] else { continue }
                let payload = try CanvasStrokeCodec.encode(
                    color: snapshot.color,
                    width: snapshot.width,
                    points: snapshot.points
                )
                let replicas = grouped[id] ?? []
                let baseline = max(
                    replicas.map(\.mutationVersion).max() ?? 0,
                    snapshot.mutationVersion
                )
                let nextVersion = try Self.nextMutationVersion(
                    after: baseline,
                    strokeID: id
                )
                prepared.append(PreparedRestore(
                    snapshot: snapshot,
                    payload: payload,
                    replicas: replicas,
                    nextVersion: nextVersion
                ))
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }

        let timestamp = now()
        for restore in prepared {
            if restore.replicas.isEmpty {
                context.insert(CanvasStrokeItem(
                    id: restore.snapshot.id,
                    payloadVersion: CanvasStrokeCodec.currentVersion,
                    payload: restore.payload,
                    boardGeneration: boardGeneration,
                    mutationVersion: restore.nextVersion,
                    tombstoned: false,
                    createdAt: restore.snapshot.createdAt,
                    updatedAt: timestamp
                ))
                continue
            }

            for replica in restore.replicas {
                replica.payloadVersion = CanvasStrokeCodec.currentVersion
                replica.payload = restore.payload
                replica.boardGeneration = boardGeneration
                replica.mutationVersion = restore.nextVersion
                replica.tombstoned = false
                replica.createdAt = restore.snapshot.createdAt
                replica.updatedAt = timestamp
                replica.deletedAt = nil
            }
        }

        return save()
    }

    @discardableResult
    func clearBoard() -> Bool {
        let replicas: [CanvasBoardItem]
        do {
            replicas = try storedBoardReplicas()
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }

        guard boardGeneration < Int64.max else {
            lastErrorMessage = CanvasReplicaMutationError.generationExhausted
                .localizedDescription
            return false
        }

        let nextGeneration = boardGeneration + 1
        let timestamp = now()
        if replicas.isEmpty {
            context.insert(CanvasBoardItem(
                id: CanvasBoardItem.logicalBoardID,
                formatVersion: CanvasStrokeCodec.currentVersion,
                clearGeneration: nextGeneration,
                updatedAt: timestamp
            ))
        } else {
            for replica in replicas {
                replica.formatVersion = CanvasStrokeCodec.currentVersion
                replica.clearGeneration = nextGeneration
                replica.updatedAt = timestamp
            }
        }

        return save()
    }

    func refresh() {
        do {
            let warning = try reloadCanvas()
            lastErrorMessage = warning
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func handleCloudSyncEvent(_ update: CloudSyncEventUpdate) {
        cloudSyncProtection.apply(update)
        reconcileProtectedCloudSyncActivity(for: update.kind)
        cloudSyncStatus.apply(update)
        if !update.succeeded, let errorMessage = update.errorMessage {
            NSLog("CloudKit %@ failed: %@", String(describing: update.kind), errorMessage)
        }

        // A failed import may still have committed earlier batches. Replace
        // the ModelContext after every completed import so cached values never
        // overwrite imported ink during the next local save.
        guard update.kind == .importData, update.endedAt != nil else { return }

        cloudImportRefreshTask?.cancel()
        cloudImportRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.refresh()
            self?.cloudSyncProtection.completeImportRefresh()
            self?.reconcileProtectedCloudSyncActivity(for: .importData)
            self?.cloudImportRefreshTask = nil
        }
    }

    @discardableResult
    private func save() -> Bool {
        do {
            try persist(context)
            cloudSyncProtection.noteLocalSave()
            reconcileProtectedCloudSyncActivity(for: .exportData)

            do {
                lastErrorMessage = try reloadCanvas()
            } catch {
                // The transaction is already durable. Keep it successful and
                // surface the refresh failure rather than pretending a saved
                // stroke was rolled back.
                lastErrorMessage = "Canvas saved, but refresh failed: \(error.localizedDescription)"
                revision &+= 1
            }
            return true
        } catch {
            let saveError = error.localizedDescription
            context.rollback()
            do {
                let warning = try reloadCanvas()
                if let warning {
                    lastErrorMessage = "\(saveError) · \(warning)"
                } else {
                    lastErrorMessage = saveError
                }
            } catch {
                lastErrorMessage = "\(saveError) · Reload failed: \(error.localizedDescription)"
            }
            return false
        }
    }

    private func reloadCanvas() throws -> String? {
        let refreshedContext = ModelContext(container)
        let boardReplicas = try refreshedContext.fetch(
            FetchDescriptor<CanvasBoardItem>()
        )
        let strokeReplicas = try refreshedContext.fetch(
            FetchDescriptor<CanvasStrokeItem>()
        )

        let relevantBoards = boardReplicas.filter {
            $0.id == CanvasBoardItem.logicalBoardID
        }
        let resolvedGeneration = relevantBoards
            .map(\.clearGeneration)
            .max() ?? 0

        var warnings: [String] = []
        var omittedWarningCount = 0
        func recordWarning(_ warning: String) {
            if warnings.count < 3 {
                warnings.append(warning)
            } else {
                omittedWarningCount += 1
            }
        }

        if relevantBoards.contains(where: {
            $0.formatVersion != CanvasStrokeCodec.currentVersion
        }) {
            recordWarning("The canvas board format is newer than this version of Attic.")
        }

        var winnerByID: [UUID: CanvasStrokeItem] = [:]
        for replica in strokeReplicas {
            guard let existing = winnerByID[replica.id] else {
                winnerByID[replica.id] = replica
                continue
            }
            if Self.prefers(replica, over: existing) {
                winnerByID[replica.id] = replica
            }
        }

        var nextCache: [CanvasStrokeCacheKey: CanvasStroke] = [:]
        nextCache.reserveCapacity(winnerByID.count)
        var visible: [CanvasStroke] = []
        visible.reserveCapacity(winnerByID.count)
        for id in winnerByID.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let replica = winnerByID[id],
                  replica.boardGeneration == resolvedGeneration,
                  !replica.tombstoned else {
                continue
            }

            let cacheKey = CanvasStrokeCacheKey(
                id: replica.id,
                payloadVersion: replica.payloadVersion,
                payload: replica.payload,
                boardGeneration: replica.boardGeneration,
                mutationVersion: replica.mutationVersion,
                createdAt: replica.createdAt,
                updatedAt: replica.updatedAt
            )
            if let cached = visibleStrokeCache[cacheKey] {
                nextCache[cacheKey] = cached
                visible.append(cached)
                continue
            }

            do {
                let geometry = try decodeStroke(
                    replica.payload,
                    replica.payloadVersion
                )
                let decoded = CanvasStroke(
                    id: replica.id,
                    color: geometry.color,
                    width: geometry.width,
                    points: geometry.points,
                    boardGeneration: replica.boardGeneration,
                    mutationVersion: replica.mutationVersion,
                    createdAt: replica.createdAt,
                    updatedAt: replica.updatedAt
                )
                nextCache[cacheKey] = decoded
                visible.append(decoded)
            } catch {
                recordWarning(
                    "Stroke \(replica.id.uuidString) was retained but could not be rendered: "
                        + error.localizedDescription
                )
            }
        }

        visible.sort {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt < $1.updatedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }

        if omittedWarningCount > 0 {
            warnings.append("\(omittedWarningCount) additional canvas warning(s) were omitted.")
        }

        context = refreshedContext
        visibleStrokeCache = nextCache
        boardGeneration = resolvedGeneration
        strokes = visible
        revision &+= 1
        return warnings.isEmpty ? nil : warnings.joined(separator: " · ")
    }

    private func storedBoardReplicas() throws -> [CanvasBoardItem] {
        try context.fetch(FetchDescriptor<CanvasBoardItem>()).filter {
            $0.id == CanvasBoardItem.logicalBoardID
        }
    }

    private func storedStrokeReplicas(
        matching ids: Set<UUID>
    ) throws -> [UUID: [CanvasStrokeItem]] {
        guard !ids.isEmpty else { return [:] }
        let stored = try context.fetch(FetchDescriptor<CanvasStrokeItem>())
        return Dictionary(
            grouping: stored.filter { ids.contains($0.id) },
            by: \.id
        )
    }

    private static func winningReplica(
        in replicas: [CanvasStrokeItem]
    ) throws -> CanvasStrokeItem {
        guard var winner = replicas.first else {
            throw CanvasReplicaMutationError.missingStroke(UUID())
        }

        for candidate in replicas.dropFirst() where prefers(candidate, over: winner) {
            winner = candidate
        }
        return winner
    }

    private static func prefers(
        _ candidate: CanvasStrokeItem,
        over existing: CanvasStrokeItem
    ) -> Bool {
        if candidate.mutationVersion != existing.mutationVersion {
            return candidate.mutationVersion > existing.mutationVersion
        }
        if candidate.boardGeneration != existing.boardGeneration {
            return candidate.boardGeneration > existing.boardGeneration
        }
        if candidate.tombstoned != existing.tombstoned {
            return candidate.tombstoned
        }
        if candidate.updatedAt != existing.updatedAt {
            return candidate.updatedAt > existing.updatedAt
        }
        if candidate.payloadVersion != existing.payloadVersion {
            return candidate.payloadVersion > existing.payloadVersion
        }
        if candidate.payload != existing.payload {
            return existing.payload.lexicographicallyPrecedes(candidate.payload)
        }
        if candidate.createdAt != existing.createdAt {
            return candidate.createdAt > existing.createdAt
        }
        if candidate.deletedAt != existing.deletedAt {
            return (candidate.deletedAt ?? .distantPast)
                > (existing.deletedAt ?? .distantPast)
        }
        return String(reflecting: candidate.persistentModelID)
            > String(reflecting: existing.persistentModelID)
    }

    private static func preferredSnapshot(
        _ candidate: CanvasStroke,
        over existing: CanvasStroke
    ) -> Bool {
        if candidate.mutationVersion != existing.mutationVersion {
            return candidate.mutationVersion > existing.mutationVersion
        }
        if candidate.boardGeneration != existing.boardGeneration {
            return candidate.boardGeneration > existing.boardGeneration
        }
        if candidate.updatedAt != existing.updatedAt {
            return candidate.updatedAt > existing.updatedAt
        }
        return candidate.id.uuidString > existing.id.uuidString
    }

    private static func nextMutationVersion(
        after version: Int64,
        strokeID: UUID
    ) throws -> Int64 {
        guard version < Int64.max else {
            throw CanvasReplicaMutationError.mutationVersionExhausted(strokeID)
        }
        return max(version, 0) + 1
    }

    private func observeRemoteChanges() {
        remoteChangeObservation = NotificationCenter.default.publisher(
            for: .NSPersistentStoreRemoteChange
        )
        .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.refresh()
        }
    }

    private func observeCloudKitEvents() {
        cloudKitEventObservation = NotificationCenter.default.publisher(
            for: NSPersistentCloudKitContainer.eventChangedNotification
        )
        .compactMap { notification in
            notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event
        }
        .receive(on: DispatchQueue.main)
        .sink { [weak self] event in
            guard let self, let kind = Self.activityKind(for: event.type) else { return }
            handleCloudSyncEvent(CloudSyncEventUpdate(
                id: event.identifier,
                kind: kind,
                endedAt: event.endDate,
                succeeded: event.succeeded,
                errorMessage: Self.cloudSyncErrorMessage(event.error)
            ))
        }
    }

    private func reconcileProtectedCloudSyncActivity(
        for kind: CloudSyncActivityKind
    ) {
        let shouldProtect: Bool
        switch kind {
        case .exportData:
            shouldProtect = cloudSyncProtection.protectsExport
        case .importData:
            shouldProtect = cloudSyncProtection.protectsImport
        case .setup:
            return
        }

        if shouldProtect {
            beginProtectedCloudSyncActivity(for: kind)
        } else {
            endProtectedCloudSyncActivity(for: kind)
        }
    }

    private func beginProtectedCloudSyncActivity(
        for kind: CloudSyncActivityKind
    ) {
#if os(macOS)
        guard kind != .setup else { return }

        let processInfo = ProcessInfo.processInfo
        switch kind {
        case .exportData:
            if exportActivityToken == nil {
                exportActivityToken = processInfo.beginActivity(
                    options: .userInitiatedAllowingIdleSystemSleep,
                    reason: "Exporting Attic canvas ink to iCloud"
                )
            }
            exportActivityTimeoutTask?.cancel()
            exportActivityTimeoutTask = activityTimeoutTask(for: .exportData)
        case .importData:
            if importActivityToken == nil {
                importActivityToken = processInfo.beginActivity(
                    options: .userInitiatedAllowingIdleSystemSleep,
                    reason: "Importing Attic canvas ink from iCloud"
                )
            }
            importActivityTimeoutTask?.cancel()
            importActivityTimeoutTask = activityTimeoutTask(for: .importData)
        case .setup:
            break
        }
#endif
    }

    private func endProtectedCloudSyncActivity(
        for kind: CloudSyncActivityKind
    ) {
#if os(macOS)
        switch kind {
        case .exportData:
            exportActivityTimeoutTask?.cancel()
            exportActivityTimeoutTask = nil
            if let exportActivityToken {
                ProcessInfo.processInfo.endActivity(exportActivityToken)
                self.exportActivityToken = nil
            }
        case .importData:
            importActivityTimeoutTask?.cancel()
            importActivityTimeoutTask = nil
            if let importActivityToken {
                ProcessInfo.processInfo.endActivity(importActivityToken)
                self.importActivityToken = nil
            }
        case .setup:
            break
        }
#endif
    }

#if os(macOS)
    private func activityTimeoutTask(
        for kind: CloudSyncActivityKind
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.cloudSyncActivityTimeout)
            guard !Task.isCancelled else { return }
            self?.endProtectedCloudSyncActivity(for: kind)
        }
    }
#endif

    private static func activityKind(
        for type: NSPersistentCloudKitContainer.EventType
    ) -> CloudSyncActivityKind? {
        switch type {
        case .setup: .setup
        case .import: .importData
        case .export: .exportData
        @unknown default: nil
        }
    }

    private static func cloudSyncErrorMessage(_ error: Error?) -> String? {
        guard let error else { return nil }
        let nsError = error as NSError
        var message = "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            message += " · \(underlyingError.domain) \(underlyingError.code): "
                + underlyingError.localizedDescription
        }
        return message
    }
}
