import Foundation
import SwiftData

/// Local history for one registered container. No live SwiftData objects escape a read or write.
/// As on Mac, version/proposal lists are presentation views; restore admits complete physical families.
@MainActor
struct PhoneNoteHistory {
    enum Failure: Error, Equatable { case missing, deleted, stale, mixedOwner, invalidVersion, readOnly, revisionLimit }

    struct Head: Equatable {
        let source: PhoneNoteDocument.Snapshot
        fileprivate let generation: Int64
        fileprivate let links: Set<Link>
    }
    struct Listing {
        let head: Head
        let versions: [Version]       // newest first
        let proposals: [Proposal]     // oldest first; review and application are Mac-only
    }
    struct Version: Identifiable {
        let id: UUID, noteID: UUID, createdAt: Date
        let reasonRaw: String, contentFormat: Int, content: Data?, title: String, body: String
        let attachmentIDsRaw: String, sourceRevisionID: UUID?, taskSnapshotData: Data?
        var reason: NoteVersionReason? { .init(rawValue: reasonRaw) }

        fileprivate init(_ row: NoteVersion) {
            id = row.id; noteID = row.noteID; createdAt = row.createdAt; reasonRaw = row.reasonRaw
            contentFormat = row.contentFormat; content = row.content; title = row.title; body = row.body
            attachmentIDsRaw = row.attachmentIDsRaw; sourceRevisionID = row.sourceRevisionID; taskSnapshotData = row.taskSnapshotData
        }
        fileprivate func matches(_ other: Version) -> Bool {
            id == other.id && noteID == other.noteID && createdAt == other.createdAt && content == other.content &&
            contentFormat == other.contentFormat && sourceRevisionID == other.sourceRevisionID && taskSnapshotData == other.taskSnapshotData &&
            reasonRaw.utf8.elementsEqual(other.reasonRaw.utf8) && attachmentIDsRaw.utf8.elementsEqual(other.attachmentIDsRaw.utf8) &&
            title.utf8.elementsEqual(other.title.utf8) && body.utf8.elementsEqual(other.body.utf8)
        }
    }
    struct Proposal: Identifiable {
        let id: UUID, noteID: UUID, baseVersionID: UUID?, workspaceTaskID: UUID?
        let createdAt: Date, agentName: String, baseRevisionToken: String, proposedContent: Data?
        let needsReview: Bool, isDeletion: Bool
        fileprivate init(_ row: NotePendingEdit) {
            id = row.id; noteID = row.noteID; baseVersionID = row.baseVersionID; workspaceTaskID = row.workspaceTaskID
            createdAt = row.createdAt; agentName = row.agentName; baseRevisionToken = row.baseRevisionToken
            proposedContent = row.proposedContent; needsReview = row.needsReview; isDeletion = row.isDeletion
        }
    }
    private let container: ModelContainer
    private let now: () -> Date
    private let save: (ModelContext) throws -> Void
    init(container: ModelContainer, now: @escaping () -> Date = { Date() },
         save: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.container = container; self.now = now; self.save = save
    }

    func load(noteID: UUID) throws -> Listing {
        let c = context()
        let (head, _) = try family(noteID, in: c)
        let predicate: Predicate<NotePendingEdit>
        if let owner = head.source.taskID { predicate = #Predicate { $0.noteID == noteID || $0.workspaceTaskID == owner } }
        else { predicate = #Predicate { $0.noteID == noteID } }
        let ps = try c.fetch(FetchDescriptor<NotePendingEdit>(predicate: predicate)).sorted { a, b in
            a.createdAt == b.createdAt ? a.id.uuidString < b.id.uuidString : a.createdAt < b.createdAt
        }
        var seenP = Set<UUID>()
        return try Listing(head: head, versions: versions(noteID, in: c),
                       proposals: ps.filter { seenP.insert($0.id).inserted }.map(Proposal.init))
    }

    /// Reading retained versions does not depend on a live note being in a writable state.
    func versions(noteID: UUID) throws -> [Version] { try versions(noteID, in: context()) }
    private func versions(_ noteID: UUID, in c: ModelContext) throws -> [Version] {
        let rows = try c.fetch(FetchDescriptor<NoteVersion>(predicate: #Predicate { $0.noteID == noteID })).sorted { a, b in
            a.createdAt == b.createdAt ? a.id.uuidString > b.id.uuidString : a.createdAt > b.createdAt
        }
        var seen = Set<UUID>()
        return rows.filter { seen.insert($0.id).inserted }.map(Version.init)
    }

    /// Pause/leave checkpoints never touch the live note. Return the number of new physical snapshots.
    @discardableResult func checkpoint(_ head: Head, reason: NoteVersionReason) throws -> Int {
        try transaction { c in
            let (rows, document) = try validate(head, in: c)
            return try preserve(rows, document: document, task: taskHead(head, in: c), reason: reason, at: now(), in: c)
        }
    }

    /// Always a new content revision, even when restoring byte-identical writing. No proposal, task,
    /// version or unrelated note field is rewritten. A failure rolls back the safety checkpoint too.
    @discardableResult func restore(_ selected: Version, against head: Head) throws -> PhoneNoteDocument.Snapshot {
        try transaction { c in
            let (rows, current) = try validate(head, in: c)
            guard head.source.revision < .max else { throw Failure.revisionLimit }
            guard selected.noteID == head.source.noteID else { throw Failure.invalidVersion }
            let versionID = selected.id
            let copies = try c.fetch(FetchDescriptor<NoteVersion>(predicate: #Predicate { $0.id == versionID }))
            guard !copies.isEmpty, copies.allSatisfy({ selected.matches(Version($0)) }),
                  selected.reason != nil, selected.attachmentIDsRaw.split(separator: " ").allSatisfy({ UUID(uuidString: String($0)) != nil }),
                  selected.taskSnapshotData.map(TaskHead.isReadable) ?? true,
                  let original = selected.content else { throw Failure.invalidVersion }
            let historical = try decoded(original, format: selected.contentFormat, noteID: selected.noteID)
            let task = try taskHead(head, in: c)
            let (bytes, restored) = try normalized(original, historical: historical, current: current, owner: task, head: head, in: c)
            let assets = try attachmentFamily(head.source.noteID, references: Set(restored.attachmentIDs).union(current.attachmentIDs), in: c)
            // Keep the previous presentation winner when different untouched metadata breaks a tie.
            guard let preferred = rows.max(by: Self.noteLess) else { throw Failure.missing }
            let stamp = max(now(), preferred.updatedAt), token = UUID()
            try preserve(rows, document: current, task: task, reason: .beforeRestore, at: stamp, in: c)
            let title = restored.title.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            let body = NoteTextExport.plainBody(restored), plain = NoteTextExport.plainText(restored)
            let files = restored.blocks.filter { $0.kind == .file }, images = restored.blocks.filter { $0.kind == .image }.count
            for row in rows {
                row.content = bytes; row.contentFormat = restored.format; row.title = title; row.body = body; row.plainText = plain
                row.imageCount = images; row.fileCount = files.count; row.firstFileName = files.first?.filename
                row.revision = head.source.revision + 1; row.revisionID = token; row.updatedAt = stamp
                row.deletedAttachmentIDsRaw = nil
            }
            if rows.contains(where: { $0 !== preferred && Self.noteLess(preferred, $0) }) {
                preferred.updatedAt = Date(timeIntervalSinceReferenceDate: stamp.timeIntervalSinceReferenceDate.nextUp)
            }
            let shown = Set(restored.attachmentIDs)
            for asset in assets where (asset.deletedAt == nil) != shown.contains(asset.id) {
                asset.deletedAt = shown.contains(asset.id) ? nil : stamp; asset.updatedAt = stamp
            }
            return PhoneNoteDocument.Snapshot(preferred)
        }
    }

    private func context() -> ModelContext { let c = ModelContext(container); c.autosaveEnabled = false; return c }
    private func transaction<T>(_ work: (ModelContext) throws -> T) throws -> T {
        let c = context()
        do { let result = try work(c); if c.hasChanges { try save(c) }; return result }
        catch { c.rollback(); throw error }
    }
    private static func noteLess(_ a: NoteItem, _ b: NoteItem) -> Bool {
        if a.updatedAt != b.updatedAt { return a.updatedAt < b.updatedAt }
        // The validated family has identical format/token and no deletion date (PhoneLibrary.noteLess).
        func key(_ r: NoteItem) -> String {
            [r.title, r.body, String(r.createdAt.timeIntervalSinceReferenceDate.bitPattern),
             r.tagsRaw, String(reflecting: r.persistentModelID)].joined(separator: "\u{1F}")
        }
        return key(a) < key(b)
    }
    fileprivate struct Link: Hashable {
        let id: UUID, task: UUID, note: UUID, taskGeneration: Int64, noteGeneration: Int64
        let detached: Date?, preservation: UUID?
        init(_ r: TaskNoteAssociation) {
            id = r.id; task = r.taskID; note = r.noteID; taskGeneration = r.taskGeneration; noteGeneration = r.noteGeneration
            detached = r.detachedAt; preservation = r.detachedPreservationID
        }
    }
    private func family(_ id: UUID, in c: ModelContext) throws -> (Head, [NoteItem]) {
        let rows = try c.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id }))
        guard let first = rows.first else { throw Failure.missing }
        guard rows.allSatisfy({ $0.deletedAt == nil }) else { throw Failure.deleted }
        guard rows.allSatisfy({ $0.taskID == first.taskID && $0.associationGeneration == first.associationGeneration }) else { throw Failure.mixedOwner }
        let base = PhoneNoteDocument.Snapshot(first)
        guard rows.allSatisfy({ PhoneNoteDocument.Snapshot($0) == base }) else { throw Failure.stale }
        let predicate: Predicate<TaskNoteAssociation>
        if let owner = first.taskID { predicate = #Predicate { $0.noteID == id || $0.taskID == owner } }
        else { predicate = #Predicate { $0.noteID == id } }
        let discovered = try c.fetch(FetchDescriptor<TaskNoteAssociation>(predicate: predicate))
        let ids = Array(Set(discovered.map(\.id)))
        let copies = ids.isEmpty ? [] : try c.fetch(FetchDescriptor<TaskNoteAssociation>(predicate: #Predicate { ids.contains($0.id) }))
        let links = Set(copies.map(Link.init))
        guard links.count == ids.count, links.allSatisfy({ link in
            link.detached != nil || (link.preservation == nil && link.task == base.taskID && link.note == id && link.noteGeneration == first.associationGeneration)
        }) else { throw Failure.mixedOwner }
        return (Head(source: base, generation: first.associationGeneration, links: links.filter { $0.note == id }), rows)
    }
    private func validate(_ head: Head, in c: ModelContext) throws -> ([NoteItem], NoteDocument) {
        let (fresh, rows) = try family(head.source.noteID, in: c)
        guard fresh == head else { throw Failure.stale }
        guard let bytes = fresh.source.content else { throw Failure.readOnly }
        let doc = try decoded(bytes, format: fresh.source.contentFormat, noteID: fresh.source.noteID)
        guard !doc.requires.contains("taskNote") || fresh.source.taskID != nil else { throw Failure.mixedOwner }
        return (rows, doc)
    }
    private func decoded(_ bytes: Data, format: Int, noteID: UUID) throws -> NoteDocument {
        guard format == NoteDocument.currentFormat, case let .editable(doc) = NoteContentCodec.decode(bytes) else { throw Failure.readOnly }
        if !doc.requires.contains("taskNote") {
            // Admission uses the same direct-member ambiguity check as native phone editing. A
            // decoded preview alone cannot authorize changing the visibility of attachment rows.
            let input = PhoneNoteDocument.Snapshot(noteID: noteID, content: bytes, contentFormat: format,
                contentFingerprint: nil, revision: 0, revisionID: nil, taskID: nil)
            guard PhoneNoteDocument(input).readOnlyReason == nil else { throw Failure.readOnly }
        }
        return doc
    }

    // The Mac coalesces by native bytes, exact title/body spelling and task snapshot (not reason or revision token).
    // Check every state at the newest timestamp so siblings checkpointed together coalesce on a repeated leave.
    @discardableResult private func preserve(_ rows: [NoteItem], document: NoteDocument, task: TaskHead?,
                                             reason: NoteVersionReason, at stamp: Date, in c: ModelContext) throws -> Int {
        guard let first = rows.first else { throw Failure.missing }
        let id = first.id, taskBytes = try task?.encoded(), manifest = NoteVersion.encodeIDs(document.attachmentIDs)
        var latest = FetchDescriptor<NoteVersion>(predicate: #Predicate { $0.noteID == id }, sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        latest.fetchLimit = 1
        var saved = Set<Spelling>()
        if let time = try c.fetch(latest).first?.createdAt {
            let batch = try c.fetch(FetchDescriptor<NoteVersion>(predicate: #Predicate { $0.noteID == id && $0.createdAt == time }))
            let ids = Array(Set(batch.map(\.id)))
            let all = try c.fetch(FetchDescriptor<NoteVersion>(predicate: #Predicate { ids.contains($0.id) }))
            for group in Dictionary(grouping: all, by: \.id).values {
                guard let v = group.first, v.noteID == id, v.reason != nil, v.contentFormat == first.contentFormat,
                      v.content == first.content, v.attachmentIDsRaw == manifest, v.taskSnapshotData == taskBytes else { continue }
                let selected = Version(v)
                if group.allSatisfy({ selected.matches(Version($0)) }) { saved.insert(Spelling(v.title, v.body)) }
            }
        }
        var count = 0
        for row in rows where saved.insert(Spelling(row.title, row.body)).inserted {
            c.insert(NoteVersion(noteID: id, createdAt: stamp, reason: reason, content: row.content,
                contentFormat: row.contentFormat, title: row.title, body: row.body, attachmentIDs: document.attachmentIDs,
                sourceRevisionID: row.revisionID, taskSnapshotData: taskBytes)); count += 1
        }
        return count
    }
    private struct Spelling: Hashable {
        let title: Data, body: Data
        init(_ title: String, _ body: String) { self.title = Data(title.utf8); self.body = Data(body.utf8) }
    }
    private func attachmentFamily(_ id: UUID, references: Set<UUID>, in c: ModelContext) throws -> [NoteAttachment] {
        // A missing asset is retained as a placement; never manufacture, erase or fetch payloads.
        var request = FetchDescriptor<NoteAttachment>(predicate: #Predicate { $0.noteID == id }); request.propertiesToFetch = [\.id]
        let ids = Array(references.union(try c.fetch(request).map(\.id)))
        guard !ids.isEmpty else { return [] }
        let rows = try c.fetch(FetchDescriptor<NoteAttachment>(predicate: #Predicate { ids.contains($0.id) }))
        guard rows.allSatisfy({ $0.noteID == id }) else { throw Failure.mixedOwner }
        return rows
    }
}

// MARK: - Task-page compatibility

private extension PhoneNoteHistory {
    // Wire shape of the Mac's TaskNotePageSnapshot, whose rendering code belongs to AppKit.
    struct TaskHead: Codable {
        struct Child: Codable { let id: UUID; let title: String; let isDone: Bool }
        var format = 1
        let title: String, status: String, priority: String, dueDay: DueDay?, completedAt: Date?, tags: [String], children: [Child]
        func encoded() throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(self) }
        static func isReadable(_ data: Data) -> Bool { (try? JSONDecoder().decode(Self.self, from: data))?.format == 1 }
    }
    func taskHead(_ head: Head, in c: ModelContext) throws -> TaskHead? {
        guard let owner = head.source.taskID else { return nil }
        var childQuery = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.parentID == owner })
        childQuery.propertiesToFetch = [\.id]
        let ids = Array(Set(try c.fetch(childQuery).map(\.id)).union([owner]))
        let all = try c.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { ids.contains($0.id) }))
        // Query complete families: never fold a reparented/deleted sibling into a live page snapshot.
        let rows = try Dictionary(grouping: all, by: \.id).values.map { family -> TaskItem in
            let r = family[0]
            guard family.allSatisfy({ $0.parentID == r.parentID && $0.deletedAt == r.deletedAt &&
                $0.title.utf8.elementsEqual(r.title.utf8) && $0.statusRaw == r.statusRaw && $0.priorityRaw == r.priorityRaw &&
                $0.completedAt == r.completedAt && $0.dueDayRaw == r.dueDayRaw && $0.tagsRaw == r.tagsRaw &&
                $0.manualOrder == r.manualOrder && $0.createdAt == r.createdAt && $0.associationGeneration == r.associationGeneration })
            else { throw Failure.mixedOwner }; return r
        }
        guard let r = rows.first(where: { $0.id == owner }), r.deletedAt == nil,
              head.links.allSatisfy({ $0.detached != nil || $0.taskGeneration == r.associationGeneration })
        else { throw Failure.mixedOwner }
        let children = rows.filter { $0.parentID == owner && $0.deletedAt == nil }.map {
            OrderedChild(id: $0.id, title: $0.title, isDone: $0.status == .done, order: $0.manualOrder, createdAt: $0.createdAt)
        }.sorted(by: OrderedChild.precedes)
        return TaskHead(title: r.title, status: r.statusRaw, priority: r.priorityRaw, dueDay: r.dueDay,
            completedAt: r.completedAt, tags: r.tags, children: children.map { .init(id: $0.id, title: $0.title, isDone: $0.isDone) })
    }
    struct OrderedChild {
        let id: UUID, title: String, isDone: Bool, order: Int64?, createdAt: Date
        static func precedes(_ a: Self, _ b: Self) -> Bool {
            if a.isDone != b.isDone { return !a.isDone }
            if (a.order ?? 0) != (b.order ?? 0) { return (a.order ?? 0) > (b.order ?? 0) }
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id.uuidString < b.id.uuidString
        }
    }
    func normalized(_ bytes: Data, historical doc: NoteDocument, current: NoteDocument, owner: TaskHead?,
                    head: Head, in c: ModelContext) throws -> (Data, NoteDocument) {
        let marked = doc.requires.contains("taskNote")
        guard marked || current.requires.contains("taskNote") || !head.links.isEmpty else { return (bytes, doc) }
        let candidate: NoteDocument
        if let owner { candidate = try doc.taskSnapshot(title: owner.title) }
        else if !marked { return (bytes, doc) }
        else {
            let redirects = head.links.filter { $0.preservation != nil }
            if redirects.isEmpty { candidate = try doc.ordinarySnapshot(title: doc.title) }
            else {
                let keys = Set(redirects.compactMap(\.preservation)), tasks = Set(redirects.map(\.task))
                guard keys.count == 1, tasks.count == 1, let key = keys.first, let task = tasks.first else { throw Failure.mixedOwner }
                let records = try c.fetch(FetchDescriptor<TaskDeletionPreservation>(predicate: #Predicate { $0.id == key }))
                guard let first = records.first, records.allSatisfy({
                    $0.rootID == first.rootID && $0.deletedAt == first.deletedAt &&
                    $0.capturedAt == first.capturedAt && $0.provenance == first.provenance &&
                    $0.snapshot == first.snapshot && $0.purgedAt == first.purgedAt &&
                    $0.retiredAt == first.retiredAt && $0.dependencyOwnersData == first.dependencyOwnersData
                }),
                    let p = try? JSONDecoder().decode(Preservation.self, from: first.snapshot), p.rootID == first.rootID,
                    Set(p.members.map(\.id)).count == p.members.count, let retired = p.members.first(where: { $0.id == task })
                else { throw Failure.mixedOwner }
                if first.provenance == "circle removed" {
                    let id = head.source.noteID
                    let rows = try c.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id }))
                    guard let title = rows.first?.title, rows.allSatisfy({ $0.title.utf8.elementsEqual(title.utf8) }) else { throw Failure.mixedOwner }
                    candidate = try doc.ordinarySnapshot(title: title)
                } else {
                    guard first.purgedAt != nil else { throw Failure.mixedOwner }
                    var ordinary = try doc.ordinarySnapshot(title: retired.value("title", String.self))
                    let deleted = try retired.value("deletedAt", Date?.self), group = try retired.groupID()
                    let children = try p.members.filter { member in
                        try member.value("parentID", UUID?.self) == task && member.value("deletedAt", Date?.self) == deleted && member.groupID() == group
                    }.map { m in
                        try OrderedChild(id: m.id, title: m.value("title", String.self),
                            isDone: m.value("statusRaw", String.self) == TaskStatus.done.rawValue,
                            order: m.value("manualOrder", Int64?.self), createdAt: m.value("createdAt", Date.self))
                    }.sorted(by: OrderedChild.precedes)
                    ordinary.blocks.insert(contentsOf: children.map { .checklist($0.title, checked: $0.isDone) }, at: 1)
                    candidate = ordinary
                }
            }
        }
        // Preserve the whole wire image whenever the Mac's head normalization makes no change.
        // Swift String equality is canonical; a change in the owner's exact spelling still matters.
        if candidate == doc && candidate.title.utf8.elementsEqual(doc.title.utf8) { return (bytes, doc) }
        // A rewrite is permitted only when the current codec reproduces the original wire image.
        // In particular it cannot round a future numeric extra or drop an explicit field silently.
        guard try NoteContentCodec.encode(doc) == bytes else { throw Failure.readOnly }
        return (try NoteContentCodec.encode(candidate), candidate)
    }
    // Read only the Mac preservation fields needed to materialize writing. Never reinstall its task records.
    struct Preservation: Decodable {
        let rootID: UUID, members: [Member]
        struct Member: Decodable {
            let id: UUID, fields: [String: Data]
            func value<T: Decodable>(_ key: String, _ type: T.Type) throws -> T {
                guard let bytes = fields[key] else { throw Failure.mixedOwner }; return try JSONDecoder().decode(type, from: bytes)
            }
            func groupID() throws -> UUID? { try fields["deletionGroupID"].flatMap { try JSONDecoder().decode(UUID?.self, from: $0) } }
        }
    }
}
