import Combine
import CoreData
import CryptoKit
import Foundation
import SwiftData

struct NoteExternalRecord: Equatable, Sendable {
    let id: UUID
    let title: String
    let body: String
    let createdAt: Date
    let updatedAt: Date
    let revision: String
}

enum NoteExternalAccessError: Error, Equatable, Sendable {
    case notFound
    case conflict(currentRevision: String)
    case invalidContent
    case persistenceFailure
}

enum NoteExternalAccessLimits {
    static let maximumTitleUTF8Bytes = 512
    static let maximumBodyUTF8Bytes = 262_144
}

private struct NoteReplicaSnapshot: Equatable {
    let id: UUID
    let title: String
    let body: String
    let createdAt: Date
    let updatedAt: Date

    init(_ note: NoteItem) {
        id = note.id
        title = note.title
        body = note.body
        createdAt = note.createdAt
        updatedAt = note.updatedAt
    }
}

private enum NoteReplicaMutationError: LocalizedError {
    case missingReplica(UUID)

    var errorDescription: String? {
        switch self {
        case let .missingReplica(id):
            "The note replicas for \(id.uuidString) could not be loaded safely."
        }
    }
}

/// Local-first store for notes, sharing the same CloudKit-backed container as
/// tasks. It follows the same invariants as `TaskStore`: deduplicate physical
/// replicas only for presentation, apply mutations to every replica, replace
/// the long-lived `ModelContext` after a CloudKit import, and hold a bounded
/// `ProcessInfo` activity assertion around export/import windows so the
/// `LSUIElement` Mac app does not nap while Core Data is mirroring.
@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var notes: [NoteItem] = []
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var revision: UInt64 = 0
    @Published private(set) var cloudSyncStatus = CloudSyncStatus()

    private let container: ModelContainer
    private var context: ModelContext
    private let now: () -> Date
    private let persist: (ModelContext) throws -> Void
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
        persist: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.container = container
        context = ModelContext(container)
        self.now = now
        self.persist = persist
        refresh()
        observeRemoteChanges()
        observeCloudKitEvents()
    }

    @discardableResult
    func create(title: String = "", body: String = "") -> NoteItem? {
        let normalizedTitle = Self.normalizedTitle(title)
        guard !normalizedTitle.isEmpty || Self.hasMeaningfulBody(body) else { return nil }

        let timestamp = now()
        let note = NoteItem(
            title: normalizedTitle,
            body: body,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        context.insert(note)
        notes.append(note)
        guard save() else { return nil }
        return note
    }

    @discardableResult
    func update(
        _ note: NoteItem,
        title: String? = nil,
        body: String? = nil
    ) -> Bool {
        guard let note = notes.first(where: { $0.id == note.id }) else { return false }
        let replicas: [NoteItem]
        do {
            replicas = try storedNotes(matching: note.id)
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
        let destinationTitle = title.map(Self.normalizedTitle) ?? note.title
        let destinationBody = body ?? note.body
        guard !destinationTitle.isEmpty || Self.hasMeaningfulBody(destinationBody) else { return false }

        let titleChanged = destinationTitle != note.title
        let bodyChanged = destinationBody != note.body
        let visibleSnapshot = NoteReplicaSnapshot(note)
        let replicasNeedRepair = replicas.contains { NoteReplicaSnapshot($0) != visibleSnapshot }
        guard titleChanged || bodyChanged || replicasNeedRepair else { return true }

        let timestamp = now()
        for replica in replicas {
            replica.title = destinationTitle
            replica.body = destinationBody
            replica.createdAt = note.createdAt
            replica.updatedAt = timestamp
        }
        return save()
    }

    @discardableResult
    func delete(_ note: NoteItem) -> Bool {
        guard let note = notes.first(where: { $0.id == note.id }) else { return false }
        let replicas: [NoteItem]
        do {
            replicas = try storedNotes(matching: note.id)
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
        replicas.forEach(context.delete)
        notes.removeAll { $0.id == note.id }
        return save()
    }

    /// Newest first, with a deterministic tiebreak so a refreshed duplicate
    /// keeps its position instead of flickering between physical rows.
    func orderedNotes() -> [NoteItem] {
        notes.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id.uuidString > rhs.id.uuidString
        }
    }

    /// Returns fresh, presentation-deduplicated records for non-UI clients.
    /// The opaque revision covers every physical replica of each app UUID, so
    /// an imported duplicate or edit invalidates a pending mutation instead of
    /// being silently overwritten.
    func recordsForExternalAccess() throws -> [NoteExternalRecord] {
        let stored = try loadFreshNotes()
        let replicasByID = Dictionary(grouping: stored, by: \.id)
        return visibleUniqueNotes(from: stored)
            .map { note in
                makeExternalRecord(
                    from: note,
                    replicas: replicasByID[note.id] ?? [note]
                )
            }
            .sorted(by: Self.externalRecordComesBefore)
    }

    func recordForExternalAccess(id: UUID) throws -> NoteExternalRecord {
        let stored = try loadFreshNotes()
        return try externalRecord(id: id, stored: stored)
    }

    func createForExternalAccess(title: String, body: String) throws -> NoteExternalRecord {
        guard Self.isValidExternalTitle(title),
              Self.isValidExternalBody(body),
              !Self.normalizedTitle(title).isEmpty || Self.hasMeaningfulBody(body) else {
            throw NoteExternalAccessError.invalidContent
        }
        do {
            _ = try loadFreshNotes()
        } catch {
            throw NoteExternalAccessError.persistenceFailure
        }
        guard let note = create(title: title, body: body) else {
            throw NoteExternalAccessError.persistenceFailure
        }
        return makeExternalRecord(from: note, replicas: [note])
    }

    /// Replaces only the supplied fields. `body`, when present, replaces the
    /// complete plain-text body exactly; an omitted field remains unchanged.
    func updateForExternalAccess(
        id: UUID,
        expectedRevision: String,
        title: String?,
        body: String?
    ) throws -> NoteExternalRecord {
        guard title != nil || body != nil,
              title.map(Self.isValidExternalTitle) ?? true,
              body.map(Self.isValidExternalBody) ?? true else {
            throw NoteExternalAccessError.invalidContent
        }

        let stored: [NoteItem]
        do {
            stored = try loadFreshNotes()
        } catch {
            throw NoteExternalAccessError.persistenceFailure
        }
        let replicas = stored.filter { $0.id == id }
        guard let visible = visibleUniqueNotes(from: replicas).first else {
            throw NoteExternalAccessError.notFound
        }
        let currentRevision = Self.externalRevision(for: replicas)
        guard currentRevision == expectedRevision else {
            throw NoteExternalAccessError.conflict(currentRevision: currentRevision)
        }

        let destinationTitle = title.map(Self.normalizedTitle) ?? visible.title
        let destinationBody = body ?? visible.body
        guard Self.isValidExternalTitle(destinationTitle),
              Self.isValidExternalBody(destinationBody),
              !destinationTitle.isEmpty || Self.hasMeaningfulBody(destinationBody) else {
            throw NoteExternalAccessError.invalidContent
        }

        let visibleSnapshot = NoteReplicaSnapshot(visible)
        let replicasNeedRepair = replicas.contains { NoteReplicaSnapshot($0) != visibleSnapshot }
        guard destinationTitle != visible.title
                || destinationBody != visible.body
                || replicasNeedRepair else {
            return makeExternalRecord(from: visible, replicas: replicas)
        }

        let timestamp = now()
        for replica in replicas {
            replica.title = destinationTitle
            replica.body = destinationBody
            replica.createdAt = visible.createdAt
            replica.updatedAt = timestamp
        }
        guard save() else { throw NoteExternalAccessError.persistenceFailure }
        return makeExternalRecord(from: visible, replicas: replicas)
    }

    /// Appends `content` byte-for-byte to the current plain-text body. No
    /// newline or separator is inserted implicitly.
    func appendForExternalAccess(
        id: UUID,
        expectedRevision: String,
        content: String
    ) throws -> NoteExternalRecord {
        guard !content.isEmpty,
              !content.contains("\0"),
              content.utf8.count <= NoteExternalAccessLimits.maximumBodyUTF8Bytes else {
            throw NoteExternalAccessError.invalidContent
        }
        let current = try recordForExternalAccess(id: id)
        guard current.revision == expectedRevision else {
            throw NoteExternalAccessError.conflict(currentRevision: current.revision)
        }
        guard current.body.utf8.count
                <= NoteExternalAccessLimits.maximumBodyUTF8Bytes - content.utf8.count else {
            throw NoteExternalAccessError.invalidContent
        }
        return try updateForExternalAccess(
            id: id,
            expectedRevision: expectedRevision,
            title: nil,
            body: current.body + content
        )
    }

    func deleteForExternalAccess(id: UUID, expectedRevision: String) throws {
        let stored: [NoteItem]
        do {
            stored = try loadFreshNotes()
        } catch {
            throw NoteExternalAccessError.persistenceFailure
        }
        let replicas = stored.filter { $0.id == id }
        guard !replicas.isEmpty else { throw NoteExternalAccessError.notFound }
        let currentRevision = Self.externalRevision(for: replicas)
        guard currentRevision == expectedRevision else {
            throw NoteExternalAccessError.conflict(currentRevision: currentRevision)
        }

        replicas.forEach(context.delete)
        notes.removeAll { $0.id == id }
        guard save() else { throw NoteExternalAccessError.persistenceFailure }
    }

    func refresh() {
        do {
            try reloadNotes()
            lastErrorMessage = nil
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
        // A failed import may still have committed earlier batches. Refresh
        // after every completed import so partially applied changes are not
        // left hidden behind stale SwiftData model instances.
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

    // MARK: - Persistence

    @discardableResult
    private func save() -> Bool {
        do {
            try persist(context)
            lastErrorMessage = nil
            revision &+= 1
            cloudSyncProtection.noteLocalSave()
            reconcileProtectedCloudSyncActivity(for: .exportData)
            return true
        } catch {
            let saveError = error.localizedDescription
            context.rollback()
            do {
                try reloadNotes()
                lastErrorMessage = saveError
            } catch {
                lastErrorMessage = "\(saveError) · Reload failed: \(error.localizedDescription)"
            }
            return false
        }
    }

    @discardableResult
    private func reloadNotes() throws -> [NoteItem] {
        try loadFreshNotes()
    }

    @discardableResult
    private func loadFreshNotes() throws -> [NoteItem] {
        // A long-lived ModelContext can return cached model instances after
        // CloudKit updates the underlying store. Refresh through a new context
        // so remote values replace the old objects instead of being written
        // back to CloudKit by the next local save.
        let refreshedContext = ModelContext(container)
        let fetched = try refreshedContext.fetch(FetchDescriptor<NoteItem>())
        context = refreshedContext
        notes = visibleUniqueNotes(from: fetched)
        revision &+= 1
        return fetched
    }

    /// CloudKit can't enforce a unique UUID attribute. If a malformed import
    /// ever produces duplicates, expose one app-level record. Never delete
    /// duplicates during refresh: a cleanup save could destroy the valid peer
    /// copy across CloudKit.
    private func visibleUniqueNotes(from fetched: [NoteItem]) -> [NoteItem] {
        var newestByID: [UUID: NoteItem] = [:]

        for note in fetched {
            guard let existing = newestByID[note.id] else {
                newestByID[note.id] = note
                continue
            }

            if note.updatedAt > existing.updatedAt {
                newestByID[note.id] = note
            } else if note.updatedAt == existing.updatedAt,
                      Self.tieBreakKey(for: note) > Self.tieBreakKey(for: existing) {
                newestByID[note.id] = note
            }
        }

        return fetched.filter { note in
            newestByID[note.id] === note
        }
    }

    private func storedNotes(matching id: UUID) throws -> [NoteItem] {
        let stored = try context.fetch(FetchDescriptor<NoteItem>())
        let replicas = stored.filter { $0.id == id }
        guard !replicas.isEmpty else {
            throw NoteReplicaMutationError.missingReplica(id)
        }
        return replicas
    }

    private func externalRecord(
        id: UUID,
        stored: [NoteItem]
    ) throws -> NoteExternalRecord {
        let replicas = stored.filter { $0.id == id }
        guard let visible = visibleUniqueNotes(from: replicas).first else {
            throw NoteExternalAccessError.notFound
        }
        return makeExternalRecord(from: visible, replicas: replicas)
    }

    private func makeExternalRecord(
        from note: NoteItem,
        replicas: [NoteItem]
    ) -> NoteExternalRecord {
        NoteExternalRecord(
            id: note.id,
            title: note.title,
            body: note.body,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt,
            revision: Self.externalRevision(for: replicas)
        )
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

    private func reconcileProtectedCloudSyncActivity(for kind: CloudSyncActivityKind) {
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

    /// Keep the `LSUIElement` app out of App Nap only while Core Data is handing
    /// a local note save to CloudKit or applying an import, then release the
    /// assertion immediately. The timeout is a safety net for framework events
    /// that never complete.
    private func beginProtectedCloudSyncActivity(for kind: CloudSyncActivityKind) {
#if os(macOS)
        guard kind != .setup else { return }

        let processInfo = ProcessInfo.processInfo
        switch kind {
        case .exportData:
            if exportActivityToken == nil {
                exportActivityToken = processInfo.beginActivity(
                    options: .userInitiatedAllowingIdleSystemSleep,
                    reason: "Exporting Attic notes to iCloud"
                )
            }
            exportActivityTimeoutTask?.cancel()
            exportActivityTimeoutTask = activityTimeoutTask(for: .exportData)
        case .importData:
            if importActivityToken == nil {
                importActivityToken = processInfo.beginActivity(
                    options: .userInitiatedAllowingIdleSystemSleep,
                    reason: "Importing Attic notes from iCloud"
                )
            }
            importActivityTimeoutTask?.cancel()
            importActivityTimeoutTask = activityTimeoutTask(for: .importData)
        case .setup:
            break
        }
#endif
    }

    private func endProtectedCloudSyncActivity(for kind: CloudSyncActivityKind) {
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

    private static func normalizedTitle(_ title: String) -> String {
        title
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func hasMeaningfulBody(_ body: String) -> Bool {
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isValidExternalTitle(_ title: String) -> Bool {
        !title.contains("\0")
            && title.utf8.count <= NoteExternalAccessLimits.maximumTitleUTF8Bytes
    }

    private static func isValidExternalBody(_ body: String) -> Bool {
        !body.contains("\0")
            && body.utf8.count <= NoteExternalAccessLimits.maximumBodyUTF8Bytes
    }

    private static func externalRecordComesBefore(
        _ lhs: NoteExternalRecord,
        _ rhs: NoteExternalRecord
    ) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.id.uuidString > rhs.id.uuidString
    }

    private static func externalRevision(for replicas: [NoteItem]) -> String {
        let encodedReplicas = replicas
            .map(canonicalReplicaData)
            .sorted { $0.lexicographicallyPrecedes($1) }
        var aggregate = Data()
        append(UInt64(encodedReplicas.count), to: &aggregate)
        for encoded in encodedReplicas {
            append(UInt64(encoded.count), to: &aggregate)
            aggregate.append(encoded)
        }
        let digest = Data(SHA256.hash(data: aggregate))
        let token = digest.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "v1:\(token)"
    }

    private static func canonicalReplicaData(_ note: NoteItem) -> Data {
        var data = Data()
        append(note.id.uuidString, to: &data)
        append(note.title, to: &data)
        append(note.body, to: &data)
        append(note.createdAt.timeIntervalSinceReferenceDate.bitPattern, to: &data)
        append(note.updatedAt.timeIntervalSinceReferenceDate.bitPattern, to: &data)
        return data
    }

    private static func append(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        append(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static func tieBreakKey(for note: NoteItem) -> String {
        [
            note.title,
            note.body,
            String(note.createdAt.timeIntervalSinceReferenceDate.bitPattern),
            String(note.updatedAt.timeIntervalSinceReferenceDate.bitPattern),
            String(reflecting: note.persistentModelID)
        ].joined(separator: "\u{1F}")
    }
}
