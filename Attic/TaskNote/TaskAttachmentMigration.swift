import CryptoKit
import Foundation
import ImageIO
import SwiftData

/// UX plan § 13: a task family's legacy attachments (`TaskImageReference`s
/// in `imageReferencesData` and `removedAttachmentsData`, bytes in
/// `TaskImages`) move into the task's own note, one family per S1
/// operation. The legacy lists and bytes are never written or deleted: a
/// migrated family is simply no longer read through them, an older build
/// still sees them as they were, and reversal puts the note back.
///
/// Everything here is headless and runs on any store: the app's launch
/// runner, Earlier files' Move into Note, the fixtures and the crash helper
/// all call the same functions.
@MainActor
enum TaskAttachmentMigration {
    // MARK: Values

    /// One legacy reference, resolved to the family (a child-held file
    /// belongs to the top-level task; its holder is recorded).
    struct Entry: Codable, Equatable, Sendable {
        let reference: TaskImageReference
        let holderID: UUID
        /// When it was removed (Recently Deleted); nil while shown.
        let removedAt: Date?
        var isShown: Bool { removedAt == nil }
    }

    /// One physical replica's lists, exactly as stored.
    struct ReplicaList: Codable, Equatable, Sendable {
        let taskID: UUID
        let shown: [TaskImageReference]
        let removed: [RemovedTaskAttachment]
        let dataDigest: String
    }

    /// The source manifest: every replica's lists, and the family's entries
    /// in stored order (each holder's shown files, then its removed ones).
    struct Manifest: Codable, Equatable, Sendable {
        var replicas: [ReplicaList]
        var entries: [Entry]
        /// Append-only byte provenance; source lists may later remove entries.
        /// Optional for records written before cumulative retention shipped.
        var coveredOriginals: [Entry]? = nil
        var shown: [Entry] { entries.filter(\.isShown) }
    }

    /// The note before or after a migration step.
    struct NoteState: Codable, Equatable, Sendable {
        var absent: Bool
        var revisionID: UUID?
        var documentDigest: String?
        var placementIDs: [UUID] = []
        var attachmentIDs: [UUID] = []
        var originalPlacements: [UUID: String]? = nil
        static let absentNote = NoteState(absent: true)
    }

    /// Why a family stays on the legacy path (shown in Earlier files).
    enum Refusal: Error, Equatable, Sendable {
        case unreadable
        case divergentReplicas
        case listedTwice
        case usedElsewhere(String)
        case noteNotWritable
        case tooManyFiles
        case fileTooLarge(String)
        case noteTooLarge
        case missingOriginal(String)
        case changedSinceMoving(String)
        case reversed

        /// Earlier files' header line, for example "the note would exceed 20 files".
        var reason: String {
            switch self {
            case .unreadable: String(localized: "its file list couldn't be read")
            case .divergentReplicas: String(localized: "copies of this task disagree about its files")
            case .listedTwice: String(localized: "a file is listed twice")
            case let .usedElsewhere(name): String(localized: "“\(name)” is already in another note")
            case .noteNotWritable: String(localized: "the note can't take files in this version")
            case .tooManyFiles: String(localized: "the note would exceed 20 files")
            case let .fileTooLarge(name): String(localized: "“\(name)” is larger than 15 MB")
            case .noteTooLarge: String(localized: "the note would exceed 100 MB")
            case let .missingOriginal(name): String(localized: "“\(name)” is missing its original")
            case let .changedSinceMoving(name): String(localized: "“\(name)” changed after moving")
            case .reversed: String(localized: "they were moved back out of the note")
            }
        }

        /// Limits can change (a file removed from the note); Move into Note
        /// is offered for them. The others need the data to agree first.
        var allowsMove: Bool {
            switch self {
            case .tooManyFiles, .noteTooLarge, .reversed: true
            default: false
            }
        }
    }

    enum Outcome: Equatable {
        case migrated(noteID: UUID, created: Bool)
        case reconciled
        case unchanged
        case refused(Refusal)
        /// Not now: the family is in Recently Deleted, its note is open, or
        /// the commit lost a race. Nothing changed; it runs again later.
        case deferred
    }

    /// What a family shows: on the legacy path, migrated (with any files
    /// the note could not take), or reversed.
    struct Status: Equatable {
        enum Kind: Equatable { case legacy, migrated, reversed }
        var kind: Kind
        /// Earlier files: legacy files not in the note.
        var earlier: [TaskImageReference]
        var refusal: Refusal?
        var noteID: UUID?
        static let none = Status(kind: .legacy, earlier: [], refusal: nil)
    }

    enum InjectedInterruption: Error { case at(String) }

    #if DEBUG
    /// Tests: called at every boundary (inventory, validation, bytes, note,
    /// record, publication). Throwing there abandons the operation exactly
    /// as a kill at that point would leave it (nothing after the boundary
    /// runs); the store is then reopened and launch recovery runs.
    static var interruption: ((String) throws -> Void)?
    #endif

    private static func boundary(_ point: String) throws {
        WorkspaceCrashHook.reach(point)
        #if DEBUG
        try interruption?(point)
        #endif
    }

    static let migratedState = "migrated"
    static let reversedState = "reversed"

    /// A placement's ID is a UUIDv5 of the note (namespace) and the
    /// attachment (name): a retry or another replica never duplicates it.
    nonisolated static func placementID(attachment: UUID, note: UUID) -> UUID {
        let name = withUnsafeBytes(of: note.uuid) { Array($0) } + withUnsafeBytes(of: attachment.uuid) { Array($0) }
        var hash = Array(Insecure.SHA1.hash(data: Data(name)))
        hash[6] = (hash[6] & 0x0F) | 0x50
        hash[8] = (hash[8] & 0x3F) | 0x80
        return UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
                           hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
    }

    // MARK: Inventory

    /// Top-level tasks whose family holds any legacy list, in UUID order.
    static func candidateRoots(in context: ModelContext) throws -> [UUID] {
        let rows = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate {
            $0.imageReferencesData != nil || $0.removedAttachmentsData != nil
        }))
        var roots = Set<UUID>()
        for row in rows where row.imageReferencesData?.isEmpty == false || row.removedAttachmentsData?.isEmpty == false {
            roots.insert(row.parentID ?? row.id)
        }
        roots.formUnion(try context.fetch(FetchDescriptor<TaskAttachmentMigrationRecord>()).map(\.id))
        return roots.sorted { $0.uuidString < $1.uuidString }
    }

    struct Family {
        let rootID: UUID
        let title: String
        let isDeleted: Bool
        /// The family's tasks whose legacy lists the manifest read.
        let memberIDs: [UUID]
        let manifest: Manifest
    }

    enum Inventory {
        case family(Family)
        /// The lists can't be trusted; `shown` is the lenient read, so
        /// Earlier files still lists what an older build would show.
        case refused(Refusal, shown: [TaskImageReference], isDeleted: Bool)
        case missing
    }

    /// The strict inventory of one family across every physical replica.
    static func inventory(rootID: UUID, in context: ModelContext) throws -> Inventory {
        let roots = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == rootID }))
        guard !roots.isEmpty, roots.allSatisfy({ $0.parentID == nil }) else { return .missing }
        let isDeleted = roots.contains { $0.deletedAt != nil }
        let children = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.parentID == rootID }))
            .filter { $0.deletedAt == nil }
        var created: [UUID: Date] = [:]
        for child in children { created[child.id] = min(created[child.id] ?? .distantFuture, child.createdAt) }
        let childIDs = created.keys.sorted { (created[$0]!, $0.uuidString) < (created[$1]!, $1.uuidString) }
        var lenient: [TaskImageReference] = []
        for row in roots + children {
            for reference in row.attachments where !lenient.contains(reference) { lenient.append(reference) }
        }
        let title = roots.max { $0.updatedAt < $1.updatedAt }?.title ?? roots[0].title
        var replicas: [ReplicaList] = []
        var entries: [Entry] = []
        var members: [UUID] = []
        for id in [rootID] + childIDs {
            let rows = id == rootID ? roots : children.filter { $0.id == id }
            var lists: [ReplicaList] = []
            for row in rows {
                do {
                    let shown = try row.imageReferencesData.flatMap { $0.isEmpty ? nil : $0 }
                        .map { try JSONDecoder().decode([TaskImageReference].self, from: $0) } ?? []
                    let removed = try row.removedAttachmentsData.flatMap { $0.isEmpty ? nil : $0 }
                        .map { try JSONDecoder().decode([RemovedTaskAttachment].self, from: $0) } ?? []
                    let digest = WorkspaceModelFields.digest((row.imageReferencesData ?? Data()) + Data([0]) + (row.removedAttachmentsData ?? Data()))
                    lists.append(ReplicaList(taskID: id, shown: shown, removed: removed, dataDigest: digest))
                } catch {
                    return .refused(.unreadable, shown: lenient, isDeleted: isDeleted)
                }
            }
            guard let first = lists.first else { continue }
            guard lists.allSatisfy({ $0.shown == first.shown && $0.removed == first.removed }) else {
                return .refused(.divergentReplicas, shown: lenient, isDeleted: isDeleted)
            }
            replicas += lists.sorted { $0.dataDigest < $1.dataDigest }
            guard !first.shown.isEmpty || !first.removed.isEmpty else { continue }
            members.append(id)
            entries += first.shown.map { Entry(reference: $0, holderID: id, removedAt: nil) }
            entries += first.removed.map { Entry(reference: $0.reference, holderID: id, removedAt: $0.removedAt) }
        }
        guard Set(entries.map(\.reference.id)).count == entries.count else {
            return .refused(.listedTwice, shown: entries.filter(\.isShown).map(\.reference), isDeleted: isDeleted)
        }
        return .family(Family(rootID: rootID, title: title, isDeleted: isDeleted, memberIDs: members,
                              manifest: Manifest(replicas: replicas, entries: entries)))
    }

    // MARK: The destination

    struct Destination {
        let noteID: UUID
        let exists: Bool
        let document: NoteDocument
        let before: NoteState
        /// Every row with each entry's ID (anywhere).
        let rowsByID: [UUID: [NoteAttachment]]
        let noteRows: [NoteAttachment]
        /// The note a reversal sent to Recently Deleted, brought back by
        /// Move into Note in the same commit.
        var revived = false
    }

    private static func destination(for family: Family, coordinator: WorkspaceOperationCoordinator,
                                    in context: ModelContext, ids: Set<UUID>, revive: UUID? = nil) throws -> Result<Destination, Refusal> {
        var noteID: UUID?
        do { noteID = try coordinator.sessions.resolve(.task(family.rootID)).1 }
        catch { return .failure(.noteNotWritable) }
        var revived = false
        if noteID == nil, let revive {
            let rows = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == revive }))
            if !rows.isEmpty, rows.allSatisfy({ $0.deletedAt != nil && $0.taskID == family.rootID }) { noteID = revive; revived = true }
        }
        var rowsByID: [UUID: [NoteAttachment]] = [:]
        let all = Array(ids)
        for row in try context.fetch(FetchDescriptor<NoteAttachment>(predicate: #Predicate { all.contains($0.id) })) {
            rowsByID[row.id, default: []].append(row)
        }
        guard let noteID else {
            let id = UUID()
            let document = try NoteDocument(blocks: [.text(family.title)]).taskSnapshot(title: family.title)
            return .success(Destination(noteID: id, exists: false, document: document, before: .absentNote,
                                        rowsByID: rowsByID, noteRows: []))
        }
        let replicas = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
        guard let first = replicas.first, replicas.allSatisfy({ ($0.deletedAt == nil || revived) && $0.contentFormat == NoteDocument.currentFormat }),
              let content = first.content, replicas.allSatisfy({ $0.content == content }),
              case let .editable(document) = NoteContentCodec.decode(content), document.isWritableByThisBuild,
              !document.blocks.isEmpty, document.blocks[0].kind == .text else {
            return .failure(.noteNotWritable)
        }
        let noteRows = try context.fetch(FetchDescriptor<NoteAttachment>(predicate: #Predicate { $0.noteID == noteID }))
        let before = NoteState(absent: false, revisionID: first.revisionID, documentDigest: WorkspaceModelFields.digest(content),
                               placementIDs: document.blocks.compactMap { $0.attachmentID == nil ? nil : $0.id },
                               attachmentIDs: Array(Set(noteRows.map(\.id))).sorted { $0.uuidString < $1.uuidString })
        return .success(Destination(noteID: noteID, exists: true, document: document, before: before,
                                    rowsByID: rowsByID, noteRows: noteRows, revived: revived))
    }

    /// Which entries need rows, which already count as migrated, or why the
    /// family is refused. Validated completely before anything is staged.
    private static func validate(_ entries: [Entry], into destination: Destination) -> Result<[Entry], Refusal> {
        var needed: [Entry] = []
        for entry in entries {
            let rows = destination.rowsByID[entry.reference.id] ?? []
            if rows.isEmpty { needed.append(entry); continue }
            // Already in this task's own note with the same bytes: migrated.
            guard rows.allSatisfy({ $0.noteID == destination.noteID && $0.byteCount == entry.reference.byteCount
                && $0.contentDigest.lowercased() == entry.reference.digest.lowercased() }) else {
                return .failure(.usedElsewhere(entry.reference.filename))
            }
        }
        for entry in needed where entry.isShown {
            let reference = entry.reference
            guard reference.byteCount > 0, reference.byteCount <= AttachmentLimits.maxBytesPerAttachment,
                  reference.filename.utf8.count <= AttachmentLimits.maxFilenameUTF8Bytes else {
                return .failure(.fileTooLarge(reference.filename))
            }
        }
        // Combined limits over shown files; removed ones do not count.
        var shown = Set(destination.document.attachmentIDs)
        shown.formUnion(entries.filter(\.isShown).map(\.reference.id))
        guard shown.count <= AttachmentLimits.maxAttachmentsPerNote else { return .failure(.tooManyFiles) }
        var sizes: [UUID: Int64] = [:]
        for row in destination.noteRows where shown.contains(row.id) { sizes[row.id] = max(sizes[row.id] ?? 0, row.byteCount) }
        for entry in entries where entry.isShown { sizes[entry.reference.id] = max(sizes[entry.reference.id] ?? 0, entry.reference.byteCount) }
        for block in destination.document.blocks {
            guard let id = block.attachmentID, sizes[id] == nil else { continue }
            sizes[id] = block.byteCount ?? AttachmentLimits.maxBytesPerAttachment
        }
        guard sizes.values.reduce(0, +) <= AttachmentLimits.maxBytesPerNote else { return .failure(.noteTooLarge) }
        return .success(needed)
    }

    // MARK: Bytes

    /// Reads each original from `TaskImages`, verified by digest and size,
    /// off the main actor. The leases keep the originals from collection
    /// until the commit.
    private static func readOriginals(_ entries: [Entry], files: TaskImageFiles)
        async -> Result<([StagedNoteAttachment], [WorkspaceOwnershipGate.Lease]), Refusal> {
        var staged: [StagedNoteAttachment] = []
        var leases: [WorkspaceOwnershipGate.Lease] = []
        for entry in entries {
            let reference = entry.reference
            guard let admitted = try? await files.files.admit(reference.fileReference) else {
                leases.forEach { $0.release() }
                return .failure(.missingOriginal(reference.filename))
            }
            leases.append(admitted.1)
            let url = admitted.0
            let item = await Task.detached(priority: .utility) { () -> StagedNoteAttachment? in
                guard let data = try? Data(contentsOf: url), Int64(data.count) == reference.byteCount else { return nil }
                let digest = NotePayloadDigest.sha256(data)
                guard digest == reference.digest.lowercased() else { return nil }
                return StagedNoteAttachment(id: reference.id, filename: reference.filename,
                    contentTypeIdentifier: reference.contentTypeIdentifier, byteCount: reference.byteCount,
                    digest: digest, data: data)
            }.value
            guard let item else {
                leases.forEach { $0.release() }
                return .failure(.missingOriginal(reference.filename))
            }
            staged.append(item)
        }
        return .success((staged, leases))
    }

    /// Metadata is not proof of a payload. Nil payloads are repaired from an
    /// independently verified original in the document commit; corrupt bytes refuse.
    private static func payloadRepairs(_ entries: [Entry], container: ModelContainer) async throws -> [Entry] {
        try await Task.detached(priority: .utility) {
            let context = ModelContext(container)
            var repair: [Entry] = []
            for entry in entries {
                let id = entry.reference.id
                let rows = try context.fetch(FetchDescriptor<NoteAttachment>(predicate: #Predicate { $0.id == id }))
                for row in rows {
                    guard let payload = row.payload else { continue }
                    guard Int64(payload.count) == entry.reference.byteCount,
                          NotePayloadDigest.sha256(payload) == entry.reference.digest.lowercased() else {
                        throw Refusal.changedSinceMoving(entry.reference.filename)
                    }
                }
                if rows.contains(where: { $0.payload == nil }) { repair.append(entry) }
            }
            return repair
        }.value
    }

    nonisolated private static func pixelSize(_ data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    private static func placementDigest(_ block: NoteBlock) throws -> String {
        WorkspaceModelFields.digest(try NoteContentCodec.encode(NoteDocument(blocks: [.text(""), block])))
    }

    private static func releaseVerifiedQuarantines(rootID: UUID, coordinator: WorkspaceOperationCoordinator, files: TaskImageFiles) async {
        guard let inventory = try? await coordinator.journal.operationInventory() else { return }
        for item in inventory where item.damaged && item.quarantined && item.intactIntent && item.verifiedAbort == nil {
            guard let envelope = item.envelope, envelope.intent == "Move Files into Note",
                  envelope.writes.contains(.init(entity: .migration, id: rootID)),
                  case let .family(family) = try? Self.inventory(rootID: rootID, in: coordinator.freshContext()), !family.isDeleted else { continue }
            var sources: [Entry] = []
            for payload in envelope.payloads {
                guard let entry = family.manifest.entries.first(where: {
                    $0.reference.id == payload.id && $0.reference.digest.lowercased() == payload.digest
                        && $0.reference.byteCount == payload.byteCount && $0.reference.filename == payload.filename
                        && $0.reference.contentTypeIdentifier == payload.contentType
                }) else { break }
                guard envelope.tokens.contains(where: { $0.owner == .init(entity: .task, id: entry.holderID) }) else { break }
                sources.append(entry)
            }
            guard sources.count == envelope.payloads.count, !sources.isEmpty else { continue }
            guard case let .success((bytes, leases)) = await readOriginals(sources, files: files) else { continue }
            defer { leases.forEach { $0.release() } }
            do {
                try coordinator.abortUncommittedMigration(item, rootID: rootID, verified: bytes)
                try await coordinator.reconcileStartup()
            } catch { /* Any uncertainty keeps the hold and its artifact. */ }
        }
    }

    // MARK: Migrate (and reconcile an older writer's changes)

    /// Moves one family's legacy files into its own note, as one S1
    /// operation. A family already migrated is reconciled with its current
    /// lists (an older build may have added or removed files since).
    static func migrate(rootID: UUID, coordinator: WorkspaceOperationCoordinator, files: TaskImageFiles,
                        force: Bool = false, history: WorkspaceHistory? = nil, isBusy: @escaping () -> Bool = { false }, publish: @escaping () -> Void = {}) async -> Outcome {
        do {
            guard !isBusy(), !coordinator.sessions.hasActiveTaskPage(rootID) else { return .deferred }
            await releaseVerifiedQuarantines(rootID: rootID, coordinator: coordinator, files: files)
            let context = coordinator.freshContext()
            let records = try context.fetch(FetchDescriptor<TaskAttachmentMigrationRecord>(predicate: #Predicate { $0.id == rootID }))
            if let record = records.first {
                guard records.allSatisfy({ $0.stateRaw == record.stateRaw && $0.noteID == record.noteID && $0.manifestData == record.manifestData }) else {
                    return .refused(.divergentReplicas)
                }
                if record.stateRaw == reversedState && !force { return .refused(.reversed) }
            }
            guard case let .family(family) = try inventory(rootID: rootID, in: context) else {
                if case let .refused(refusal, _, _) = try inventory(rootID: rootID, in: context) { return .refused(refusal) }
                return .unchanged
            }
            guard !family.isDeleted else { return .deferred }
            try boundary("M0-inventory")
            let previous = try records.first.flatMap { record -> Manifest? in
                guard record.stateRaw == migratedState else { return nil }
                return try JSONDecoder().decode(Manifest.self, from: record.manifestData)
            }
            let previousAfter = try records.first.flatMap { record -> NoteState? in
                guard record.stateRaw == migratedState else { return nil }
                return try JSONDecoder().decode(NoteState.self, from: record.afterData)
            }
            let ids = Set(family.manifest.entries.map(\.reference.id))
            let destination: Destination
            let revive = records.first.flatMap { $0.stateRaw == reversedState && $0.noteCreated ? $0.noteID : nil }
            switch try Self.destination(for: family, coordinator: coordinator, in: context, ids: ids, revive: revive) {
            case let .success(value): destination = value
            case let .failure(refusal): return .refused(refusal)
            }
            if previous != nil, let record = records.first, record.noteID != destination.noteID {
                return .refused(.changedSinceMoving(family.title))
            }
            // An older writer's removals: a shown file now removed (or gone)
            // leaves the note only while its placement is unchanged.
            var removals: [Entry] = []
            if let previous {
                let current = Dictionary(uniqueKeysWithValues: family.manifest.entries.map { ($0.reference.id, $0) })
                for old in previous.shown where current[old.reference.id]?.isShown != true {
                    let placement = placementID(attachment: old.reference.id, note: destination.noteID)
                    guard let block = destination.document.blocks.first(where: { $0.id == placement }),
                          block.attachmentID == old.reference.id,
                          previousAfter?.originalPlacements?[placement] == (try placementDigest(block)),
                          destination.document.blocks.filter({ $0.attachmentID == old.reference.id }).count == 1 else {
                        return .refused(.changedSinceMoving(old.reference.filename))
                    }
                    removals.append(old)
                }
            }
            let entries = family.manifest.entries.filter { entry in !removals.contains { $0.reference.id == entry.reference.id } }
            var needed: [Entry]
            switch validate(entries, into: destination) {
            case let .success(value): needed = value
            case let .failure(refusal): return .refused(refusal)
            }
            let revision = UUID()
            let noteID = destination.noteID
            let associationID = UUID()
            let noteReplicas = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
            let versions = Dictionary(uniqueKeysWithValues: noteReplicas.map { ($0.persistentModelID, UUID()) })
            var writes: Set<WorkspaceOwner> = [.init(entity: .note, id: noteID), .init(entity: .migration, id: rootID)]
            writes.formUnion(ids.union(destination.noteRows.map(\.id)).map { .init(entity: .attachment, id: $0) })
            writes.formUnion(versions.values.map { .init(entity: .version, id: $0) })
            if !destination.exists {
                writes.formUnion([.init(entity: .association, id: associationID), .init(entity: .task, id: rootID)])
            }
            let reads = writes.union(([rootID] + family.memberIDs).map { .init(entity: .task, id: $0) })
            let expected = try coordinator.capture(reads)
            let expectedScopes = try WorkspaceScopeToken.scopes(for: expected).map { try WorkspaceScopeToken.read($0, in: context) }
            try boundary("M1-validation")
            do {
                let repairs = try await payloadRepairs(entries, container: coordinator.container)
                needed += repairs.filter { repair in !needed.contains { $0.reference.id == repair.reference.id } }
            } catch let refusal as Refusal { return .refused(refusal) }
            if let previous, previous.entries == family.manifest.entries, needed.isEmpty { return .unchanged }
            let staged: [StagedNoteAttachment]
            let leases: [WorkspaceOwnershipGate.Lease]
            switch await readOriginals(needed, files: files) {
            case let .success(value): (staged, leases) = value
            case let .failure(refusal): return .refused(refusal)
            }
            defer { leases.forEach { $0.release() } }
            try boundary("M2-bytes")
            let bytes = Dictionary(uniqueKeysWithValues: staged.map { ($0.id, $0) })
            // The note after: shown files appended at the end in stored
            // order (images inline, other files as file blocks); removals
            // leave through the same body edit.
            var document = destination.document
            let removedPlacements = Set(removals.map { placementID(attachment: $0.reference.id, note: destination.noteID) })
            document.blocks.removeAll { $0.id.map(removedPlacements.contains) == true }
            var placements: [UUID] = previousAfter?.placementIDs.filter { !removedPlacements.contains($0) } ?? []
            for entry in entries where entry.isShown {
                let id = entry.reference.id
                let placement = placementID(attachment: id, note: destination.noteID)
                if !placements.contains(placement), document.blocks.contains(where: { $0.id == placement }) { placements.append(placement) }
                guard !document.attachmentIDs.contains(id) else { continue }
                if entry.reference.isImage {
                    let size = bytes[id].flatMap { pixelSize($0.data) }
                    document.blocks.append(.image(id: placement, attachmentID: id, pixelWidth: size?.0, pixelHeight: size?.1))
                } else {
                    let reference = entry.reference
                    document.blocks.append(.file(id: placement, attachmentID: id, filename: reference.filename,
                                                 contentTypeIdentifier: reference.contentTypeIdentifier, byteCount: reference.byteCount))
                }
                placements.append(placement)
            }
            document.refreshRequiredCapabilities()
            let prepared = try PreparedNoteDocument(document)
            let manifest = family.manifest
            let after = NoteState(absent: false, revisionID: revision, documentDigest: WorkspaceModelFields.digest(prepared.content),
                                  placementIDs: placements,
                                  attachmentIDs: Array(Set((previousAfter?.attachmentIDs ?? []) + entries.map(\.reference.id))).sorted { $0.uuidString < $1.uuidString })
            var recordedAfter = after
            // Preserve the first shape of each placement. A later reconciliation
            // must never bless a person's intervening resize or metadata edit.
            recordedAfter.originalPlacements = previousAfter?.originalPlacements ?? [:]
            for block in document.blocks where block.id.map(placements.contains) == true {
                if previousAfter == nil || !((previousAfter?.placementIDs ?? []).contains(block.id!)) {
                    recordedAfter.originalPlacements?[block.id!] = try placementDigest(block)
                }
            }
            let before = previousAfter == nil ? destination.before : nil
            let created = !destination.exists
            let revived = destination.revived
            let shownStaged = staged.filter { id in entries.contains { $0.reference.id == id.id && $0.isShown } }
            let removedNeeded = needed.filter { !$0.isShown }
            let entryID = UUID()
            let effect = try history.map { try WorkspaceModelFields.encode(WorkspaceHistory.ForwardEffect(workspaceID: $0.id, entryID: entryID)) }
            let envelope = try coordinator.newEnvelope(intent: "Move Files into Note", reads: expected,
                writes: writes, scopes: expectedScopes, afterDocuments: [noteID: prepared.content], staged: staged, historyEffect: effect)
            let stage: (ModelContext) throws -> Void = { commit in
                let now = Date()
                if created {
                    guard let generation = NoteStore.taskOwnerGeneration(rootID, in: commit) else { throw WorkspaceFoundationError.conflict }
                    let note = NoteItem(id: noteID, createdAt: now, updatedAt: now)
                    NoteStore.stageDocumentContent(prepared, format: document.format, on: [note], timestamp: now, revision: 0, revisionID: revision)
                    note.taskID = rootID
                    commit.insert(note)
                    let association = TaskNoteAssociation(id: associationID, taskID: rootID, noteID: noteID)
                    association.taskGeneration = generation
                    association.noteGeneration = note.associationGeneration
                    commit.insert(association)
                    try NoteStore.stageAttachmentsOfNewNote(shownStaged, document: document, noteID: noteID, context: commit, timestamp: now)
                } else {
                    if revived {
                        let notes = try commit.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
                        WorkspaceLegacyBridge.prepareMutations(notes, in: commit)
                        for note in notes { note.deletedAt = nil }
                    }
                    try NoteStore.stageDocument(in: commit, noteID: noteID, document: document, prepared: prepared,
                        revisionID: revision, versionIDs: versions, staged: shownStaged, timestamp: now)
                }
                try boundary("M3-note")
                // Removed files keep their removal date, and so their
                // recovery deadline; removed files never count toward limits.
                let existing = try commit.fetch(FetchDescriptor<NoteAttachment>(predicate: #Predicate { $0.noteID == noteID }))
                var next = (existing.map(\.sortIndex).max() ?? -1) &+ 1
                for entry in removedNeeded {
                    guard let item = bytes[entry.reference.id] else { throw WorkspaceFoundationError.conflict }
                    let family = existing.filter { $0.id == item.id }
                    if !family.isEmpty {
                        for row in family where row.payload == nil { row.payload = item.data }
                        continue
                    }
                    let row = NoteAttachment(id: item.id, noteID: noteID, originalFilename: item.filename,
                        contentTypeIdentifier: item.contentTypeIdentifier, byteCount: item.byteCount, sortIndex: next,
                        contentDigest: item.digest, createdAt: now, payload: item.data)
                    row.deletedAt = entry.removedAt
                    next &+= 1
                    commit.insert(row)
                }
                try stageRecord(rootID: rootID, noteID: noteID, created: created || revived, manifest: manifest,
                                before: before, after: recordedAfter, state: migratedState, in: commit, at: now)
                try boundary("M4-record")
            }
            let publication = WorkspaceOperationCoordinator.Publication(steps: [{ _ in
                try boundary("M5-publication")
                publish()
            }])
            let valid = { !isBusy() && !coordinator.sessions.hasActiveTaskPage(rootID) }
            let outcome: WorkspaceOperationCoordinator.Outcome
            if let history {
                outcome = await history.performCommand(using: coordinator) {
                    .init(entryID: entryID, envelope: envelope, sessionValid: valid, stage: stage, record: { operation, entry in
                        recordMove(operation: operation, entry: entry, rootID: rootID, noteID: noteID,
                            beforeDocument: destination.document, afterDocument: document, created: created,
                            manifest: manifest, previous: previous, beforeState: destination.before, afterState: recordedAfter,
                            history: history, coordinator: coordinator, publish: publish)
                    }, publication: publication)
                }
            } else {
                outcome = await coordinator.execute(envelope, sessionValid: valid, stage: stage, publication: publication)
            }
            switch outcome {
            case .committed, .publicationPending:
                return previous == nil ? .migrated(noteID: noteID, created: created) : .reconciled
            case .notCommitted, .conflict, .unknown:
                return .deferred
            }
        } catch {
            return .deferred
        }
    }

    /// Explicit moves share the task workspace cursor. Replay never deletes a
    /// row or payload, and guards the complete result before preparing its save.
    private static func recordMove(operation: UUID, entry: UUID, rootID: UUID, noteID: UUID,
                                   beforeDocument: NoteDocument, afterDocument: NoteDocument, created: Bool,
                                   manifest: Manifest, previous: Manifest?, beforeState: NoteState, afterState: NoteState,
                                   history: WorkspaceHistory, coordinator: WorkspaceOperationCoordinator,
                                   publish: @escaping () -> Void) {
        let attachmentIDs = Set(manifest.entries.map(\.reference.id)).union(beforeDocument.attachmentIDs)
        let owners = Set<WorkspaceOwner>([.init(entity: .task, id: rootID), .init(entity: .note, id: noteID), .init(entity: .migration, id: rootID)])
            .union(attachmentIDs.map { .init(entity: .attachment, id: $0) })
        var expected = try? coordinator.capture(owners)
        let scopes: Set<WorkspaceScope> = [.taskNotes(rootID), .taskAssociations(rootID), .attachments(noteID), .proposals(noteID)]
        var expectedScopes = try? WorkspaceScopeToken.read(scopes: scopes, in: coordinator.freshContext())
        history.recordOperation(id: operation, entryID: entry, name: "Move Files into Note", coordinator: coordinator,
                                attachmentIDs: attachmentIDs) { [weak coordinator] redo, cursor in
            guard let coordinator, let guards = expected, let scopeGuards = expectedScopes,
                  try coordinator.capture(owners) == guards,
                  try WorkspaceScopeToken.read(scopes: scopes, in: coordinator.freshContext()) == scopeGuards else {
                throw WorkspaceFoundationError.conflict
            }
            // A visible draft is another dependency, even before its next save.
            try coordinator.sessions.checkFileHistoryReplay(rootID: rootID)
            let context = coordinator.freshContext()
            let rows = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
            let versions = Dictionary(uniqueKeysWithValues: rows.map { ($0.persistentModelID, UUID()) })
            let document = redo ? afterDocument : beforeDocument
            let prepared = try PreparedNoteDocument(document)
            let writes = owners.subtracting([.init(entity: .task, id: rootID)])
                .union(versions.values.map { .init(entity: .version, id: $0) })
            let envelope = try coordinator.newEnvelope(intent: "Replay Move Files into Note", reads: coordinator.capture(writes.union(owners)),
                writes: writes, inverseGuards: guards, scopes: Array(scopeGuards.values), afterDocuments: [noteID: prepared.content],
                historyEffect: WorkspaceModelFields.encode(cursor), replayOf: operation)
            return .init(envelope: envelope, stage: { commit in
                try coordinator.sessions.checkFileHistoryReplay(rootID: rootID)
                let now = Date()
                for row in try commit.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID })) { row.deletedAt = nil }
                try NoteStore.stageDocument(in: commit, noteID: noteID, document: document, prepared: prepared,
                    revisionID: UUID(), versionIDs: versions, timestamp: now)
                if !redo && created {
                    for row in try commit.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID })) { row.deletedAt = now }
                }
                try stageRecord(rootID: rootID, noteID: noteID, created: created,
                    manifest: redo ? manifest : (previous ?? manifest), before: nil,
                    after: redo ? afterState : beforeState, state: redo || previous != nil ? migratedState : reversedState,
                    in: commit, at: now)
            }, publication: .init(steps: [{ _ in
                publish()
                coordinator.sessions.refreshFileHistory(rootID: rootID)
                expectedScopes = try WorkspaceScopeToken.read(scopes: scopes, in: coordinator.freshContext())
                // Use the result of this replay as the next inverse guard.
                // The assignment refers to the captured variable, not this ticket.
            }]), completion: {
                expected = try? coordinator.capture(owners)
            })
        }
    }

    /// Writes the record's changed fields to every physical replica (S10),
    /// or inserts it.
    private static func stageRecord(rootID: UUID, noteID: UUID, created: Bool, manifest: Manifest,
                                    before: NoteState?, after: NoteState, state: String,
                                    in commit: ModelContext, at now: Date) throws {
        let rows = try commit.fetch(FetchDescriptor<TaskAttachmentMigrationRecord>(predicate: #Predicate { $0.id == rootID }))
        var retained = manifest
        var covered: [Entry] = []
        for row in rows {
            let previous = try JSONDecoder().decode(Manifest.self, from: row.manifestData)
            for entry in previous.coveredOriginals ?? previous.entries where !covered.contains(where: {
                $0.holderID == entry.holderID && $0.reference == entry.reference
            }) { covered.append(entry) }
        }
        for entry in manifest.coveredOriginals ?? manifest.entries where !covered.contains(where: {
            $0.holderID == entry.holderID && $0.reference == entry.reference
        }) { covered.append(entry) }
        retained.coveredOriginals = covered
        let manifestData = try WorkspaceModelFields.encode(retained)
        let afterData = try WorkspaceModelFields.encode(after)
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") + ")"
        if rows.isEmpty {
            let row = TaskAttachmentMigrationRecord(id: rootID, noteID: noteID)
            row.noteCreated = created
            row.stateRaw = state
            row.manifestData = manifestData
            row.beforeData = try WorkspaceModelFields.encode(before ?? .absentNote)
            row.afterData = afterData
            row.build = build
            row.createdAt = now; row.updatedAt = now
            commit.insert(row)
            return
        }
        WorkspaceLegacyBridge.prepareMutations(rows, in: commit)
        for row in rows {
            if row.stateRaw != state { row.stateRaw = state }
            if row.noteID != noteID { row.noteID = noteID }
            if row.manifestData != manifestData { row.manifestData = manifestData }
            if row.afterData != afterData { row.afterData = afterData }
            if let before {
                let data = try WorkspaceModelFields.encode(before)
                if row.beforeData != data { row.beforeData = data }
                if row.noteCreated != created { row.noteCreated = created }
            }
            if row.build != build { row.build = build }
            row.updatedAt = now
        }
    }

    // MARK: Reversal (UAT and support; never automatic)

    enum ReversalOutcome: Equatable {
        case reversed
        case refused(String)
    }

    /// Takes a migrated family's files back out of its note (§ 13). It
    /// proceeds only when every placement the migration created is
    /// unchanged and nothing pending depends on it; it never deletes rows or
    /// bytes. Files added to the note since stay; files removed from the note
    /// since go back to the legacy lists as removed.
    static func reverse(rootID: UUID, coordinator: WorkspaceOperationCoordinator, publish: @escaping () -> Void = {}) async -> ReversalOutcome {
        let cant = { (detail: String) in ReversalOutcome.refused(String(localized: "Can't reverse: \(detail)")) }
        do {
            let context = coordinator.freshContext()
            let records = try context.fetch(FetchDescriptor<TaskAttachmentMigrationRecord>(predicate: #Predicate { $0.id == rootID }))
            guard let record = records.first, record.stateRaw == migratedState,
                  records.allSatisfy({ $0.stateRaw == record.stateRaw && $0.afterData == record.afterData && $0.manifestData == record.manifestData }) else {
                return cant(String(localized: "the files weren't moved, or copies of the record disagree"))
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: record.manifestData)
            let after = try JSONDecoder().decode(NoteState.self, from: record.afterData)
            let noteID = record.noteID
            let replicas = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
            guard let first = replicas.first, let content = first.content, replicas.allSatisfy({ $0.content == content && $0.deletedAt == nil }),
                  case let .editable(document) = NoteContentCodec.decode(content), document.isWritableByThisBuild else {
                return cant(String(localized: "the note changed or has copies that disagree"))
            }
            let pending = try context.fetchCount(FetchDescriptor<NotePendingEdit>(predicate: #Predicate { $0.noteID == noteID }))
            guard pending == 0 else { return cant(String(localized: "an agent's edit to the note is waiting for review")) }
            let migratedIDs = Set(manifest.entries.map(\.reference.id))
            guard !coordinator.sessions.hasActiveTaskPage(rootID),
                  !coordinator.sessions.hasActiveNotePage(noteID),
                  migratedIDs.isDisjoint(with: coordinator.retainedRecoveryBytes) else {
                return cant(String(localized: "an open page or recovery draft still uses the files"))
            }
            guard migratedIDs.isDisjoint(with: coordinator.retainedHistoryBytes) else {
                return cant(String(localized: "an Undo step still uses the files"))
            }
            let rows = try context.fetch(FetchDescriptor<NoteAttachment>(predicate: #Predicate { $0.noteID == noteID }))
            // Each shown file: its placement unchanged (it leaves), or the
            // person removed it from the note (it goes back as removed).
            var leaving = Set<UUID>()
            var removedSince: [UUID: Date] = [:]
            for entry in manifest.shown {
                let id = entry.reference.id
                let placement = placementID(attachment: id, note: noteID)
                let family = rows.filter { $0.id == id }
                if let block = document.blocks.first(where: { $0.id == placement }) {
                    guard block.attachmentID == id, block.kind == (entry.reference.isImage ? .image : .file),
                          block.widthFraction == nil, block.width == nil,
                          document.blocks.filter({ $0.attachmentID == id }).count == 1,
                          !family.isEmpty, family.allSatisfy({ $0.deletedAt == nil && $0.contentDigest.lowercased() == entry.reference.digest.lowercased() }) else {
                        return cant(String(localized: "“\(entry.reference.filename)” changed after moving"))
                    }
                    leaving.insert(placement)
                } else if !document.attachmentIDs.contains(id), let removed = family.compactMap(\.deletedAt).max() {
                    removedSince[id] = removed
                } else {
                    return cant(String(localized: "“\(entry.reference.filename)” changed after moving"))
                }
            }
            guard after.placementIDs.allSatisfy({ placement in leaving.contains(placement) || !document.blocks.contains { $0.id == placement } }) else {
                return cant(String(localized: "a moved file changed after moving"))
            }
            var reversed = document
            reversed.blocks.removeAll { $0.id.map(leaving.contains) == true }
            let prepared = try PreparedNoteDocument(reversed)
            // A note the migration created, holding nothing else now, goes
            // to Recently Deleted through the ordinary deletion (recoverable).
            let body = reversed.blocks.dropFirst()
            let deleteNote = record.noteCreated && reversed.attachmentIDs.isEmpty
                && body.allSatisfy { $0.kind == .text && $0.text.isEmpty }
            let versions = Dictionary(uniqueKeysWithValues: replicas.map { ($0.persistentModelID, UUID()) })
            let holders = Set(manifest.shown.filter { removedSince[$0.reference.id] != nil }.map(\.holderID))
            var writes: Set<WorkspaceOwner> = [.init(entity: .note, id: noteID), .init(entity: .migration, id: rootID)]
            writes.formUnion(migratedIDs.map { .init(entity: .attachment, id: $0) })
            writes.formUnion(versions.values.map { .init(entity: .version, id: $0) })
            writes.formUnion(holders.map { .init(entity: .task, id: $0) })
            let reads = writes.union(manifest.replicas.map { .init(entity: .task, id: $0.taskID) })
            let revision = UUID()
            let envelope = try coordinator.newEnvelope(intent: "Move Files Back", reads: coordinator.capture(reads),
                writes: writes, afterDocuments: [noteID: prepared.content])
            let outcome = await coordinator.execute(envelope, sessionValid: {
                !coordinator.sessions.hasActiveTaskPage(rootID) && !coordinator.sessions.hasActiveNotePage(noteID)
                    && migratedIDs.isDisjoint(with: coordinator.retainedRecoveryBytes)
                    && migratedIDs.isDisjoint(with: coordinator.retainedHistoryBytes)
            }, stage: { commit in
                let now = Date()
                try NoteStore.stageDocument(in: commit, noteID: noteID, document: reversed, prepared: prepared,
                    revisionID: revision, versionIDs: versions, timestamp: now)
                // Files removed from the note since go back as removed, with
                // their removal date: only the lists that change are written.
                for holder in holders {
                    let tasks = try commit.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == holder }))
                    WorkspaceLegacyBridge.prepareMutations(tasks, in: commit)
                    for task in tasks {
                        let shown = try task.imageReferencesData.flatMap { $0.isEmpty ? nil : $0 }
                            .map { try JSONDecoder().decode([TaskImageReference].self, from: $0) } ?? []
                        var removed = try task.removedAttachmentsData.flatMap { $0.isEmpty ? nil : $0 }
                            .map { try JSONDecoder().decode([RemovedTaskAttachment].self, from: $0) } ?? []
                        let back = shown.filter { removedSince[$0.id] != nil }
                        guard !back.isEmpty else { continue }
                        removed += back.map { RemovedTaskAttachment(reference: $0, removedAt: removedSince[$0.id]!) }
                        task.imageReferencesData = try TaskStore.encodedAttachments(shown.filter { removedSince[$0.id] == nil })
                        task.removedAttachmentsData = try TaskStore.encodedAttachments(removed)
                    }
                }
                if deleteNote {
                    let notes = try commit.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID }))
                    for note in notes { note.deletedAt = now }
                }
                try stageRecord(rootID: rootID, noteID: noteID, created: record.noteCreated, manifest: manifest,
                                before: nil, after: NoteState(absent: deleteNote, revisionID: revision,
                                    documentDigest: WorkspaceModelFields.digest(prepared.content)),
                                state: reversedState, in: commit, at: now)
            }, publication: .init(steps: [{ _ in publish() }]))
            switch outcome {
            case .committed, .publicationPending: return .reversed
            case .notCommitted, .conflict, .unknown: return cant(String(localized: "the note or task changed meanwhile"))
            }
        } catch {
            return cant(String(localized: "the record couldn't be read"))
        }
    }

    // MARK: Status and the legacy resolver

    /// What one family shows now.
    static func status(rootID: UUID, coordinator: WorkspaceOperationCoordinator, refusal known: Refusal? = nil) -> Status {
        let context = coordinator.freshContext()
        guard let records = try? context.fetch(FetchDescriptor<TaskAttachmentMigrationRecord>(predicate: #Predicate { $0.id == rootID })),
              let inventory = try? inventory(rootID: rootID, in: context) else { return .none }
        let shown: [TaskImageReference]
        switch inventory {
        case .missing: return .none
        case let .refused(refusal, lenient, _):
            return Status(kind: records.first?.stateRaw == migratedState ? .migrated : .legacy, earlier: lenient,
                          refusal: refusal, noteID: records.first?.noteID)
        case let .family(family): shown = family.manifest.shown.map(\.reference)
        }
        guard let record = records.first else {
            return Status(kind: .legacy, earlier: shown, refusal: known, noteID: nil)
        }
        if record.stateRaw == reversedState {
            return Status(kind: .reversed, earlier: shown, refusal: .reversed, noteID: record.noteID)
        }
        let migrated = Set((try? JSONDecoder().decode(NoteState.self, from: record.afterData))?.attachmentIDs ?? [])
        let covered = (try? JSONDecoder().decode(Manifest.self, from: record.manifestData))?.entries.map(\.reference) ?? []
        let earlier = shown.filter { !migrated.contains($0.id) || !covered.contains($0) }
        return Status(kind: .migrated, earlier: earlier, refusal: known, noteID: record.noteID)
    }

    /// The legacy resolver: an attachment ID from an old drag payload, a
    /// history entry or a task reference, resolved to its note placement.
    struct Resolution: Equatable {
        let ownerID: UUID
        let holderID: UUID
        let noteID: UUID
        let placementID: UUID
    }

    static func resolve(attachmentID: UUID, in context: ModelContext) -> Resolution? {
        guard let records = try? context.fetch(FetchDescriptor<TaskAttachmentMigrationRecord>(predicate: #Predicate { $0.stateRaw == "migrated" })) else { return nil }
        for record in records {
            guard let manifest = try? JSONDecoder().decode(Manifest.self, from: record.manifestData),
                  let entry = manifest.entries.first(where: { $0.reference.id == attachmentID }) else { continue }
            return Resolution(ownerID: record.id, holderID: entry.holderID, noteID: record.noteID,
                              placementID: placementID(attachment: attachmentID, note: record.noteID))
        }
        return nil
    }

    /// The family task that holds a legacy file (a child-held file's
    /// subtask), for the legacy removal path.
    static func holder(of attachmentID: UUID, rootID: UUID, in store: TaskStore) -> UUID? {
        let context = ModelContext(store.container)
        guard case let .family(family) = try? inventory(rootID: rootID, in: context) else { return nil }
        return family.manifest.entries.first { $0.reference.id == attachmentID }?.holderID
    }

    /// Attachment IDs any migration record covers: the legacy originals stay
    /// registered with both collectors (task purge and the `TaskImages`
    /// sweep never delete them; deleting them is a separate, approved step).
    static func coveredAttachmentIDs(in context: ModelContext) throws -> Set<UUID> {
        var ids = Set<UUID>()
        for record in try context.fetch(FetchDescriptor<TaskAttachmentMigrationRecord>()) {
            let manifest = try JSONDecoder().decode(Manifest.self, from: record.manifestData)
            ids.formUnion((manifest.coveredOriginals ?? manifest.entries).map(\.reference.id))
        }
        return ids
    }

    // MARK: Launch

    struct LaunchReport: Equatable {
        var migrated: Set<UUID> = []
        var reconciled: Set<UUID> = []
        var deferred: Set<UUID> = []
        var refused: [UUID: Refusal] = [:]
    }

    /// The background launch run: every family with legacy lists, one
    /// operation each. `isBusy` defers a family whose note is open.
    static func runAll(coordinator: WorkspaceOperationCoordinator, files: TaskImageFiles,
                       isBusy: @escaping (UUID) -> Bool = { _ in false }, publish: @escaping () -> Void = {}) async -> LaunchReport {
        var report = LaunchReport()
        guard let roots = try? candidateRoots(in: coordinator.freshContext()) else { return report }
        for root in roots {
            guard !Task.isCancelled else { break }
            if isBusy(root) { report.deferred.insert(root); continue }
            switch await migrate(rootID: root, coordinator: coordinator, files: files, isBusy: { isBusy(root) }, publish: publish) {
            case .migrated: report.migrated.insert(root)
            case .reconciled: report.reconciled.insert(root)
            case .unchanged: break
            case let .refused(refusal): report.refused[root] = refusal
            case .deferred: report.deferred.insert(root)
            }
        }
        return report
    }
}
