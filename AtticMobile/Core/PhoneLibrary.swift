import Foundation
import SwiftData

/// The caller supplies the registered Attic container. No model or mutable context
/// escapes a transaction; a new read therefore also sees commits from other writers.
@MainActor
final class PhoneLibrary {
    enum Failure: LocalizedError, Equatable {
        case missingItem, inactiveReplica, emptyTask, emptyNote, invalidTime, taskFamily, orderLimit
        case readOnlyNote, staleNote, revisionLimit

        var errorDescription: String? {
            switch self {
            case .missingItem: "This item no longer exists."
            case .inactiveReplica: "This item has a deleted or archived copy."
            case .emptyTask: "A task needs a title."
            case .emptyNote: "A note needs a title or some writing."
            case .invalidTime: "Set a date and a time between 00:00 and 23:59."
            case .taskFamily: "This change conflicts with the state of the main task or its subtasks."
            case .orderLimit: "There is no room at the top of this task order."
            case .readOnlyNote: "This writing cannot be changed safely with the plain text editor."
            case .staleNote: "The stored writing has changed. Reopen it before editing."
            case .revisionLimit: "The note revision cannot be advanced."
            }
        }
    }

    struct TaskRow: Identifiable {
        let id: UUID, title: String, priority: TaskPriority, status: TaskStatus, listedStatus: TaskStatus
        let dueDay: DueDay?, dueTimeMinutes: Int?, tags: [String], parentID: UUID?
        let createdAt: Date, updatedAt: Date, completedAt: Date?, manualOrder: Int64?

        fileprivate init(_ row: TaskItem) {
            id = row.id; title = row.title; priority = row.priority; status = row.status; listedStatus = row.listedStatus
            dueDay = row.dueDay; dueTimeMinutes = row.dueTimeMinutes; tags = row.tags; parentID = row.parentID
            createdAt = row.createdAt; updatedAt = row.updatedAt; completedAt = row.completedAt; manualOrder = row.manualOrder
        }
    }

    /// List reads do not open external document or attachment bytes.
    struct NoteRow: Identifiable {
        let id: UUID, title: String, body: String, tags: [String], pinnedAt: Date?, taskID: UUID?
        let createdAt: Date, updatedAt: Date, imageCount: Int, fileCount: Int, firstFileName: String?

        fileprivate init(_ row: NoteItem) {
            id = row.id; title = row.title; body = row.body; tags = row.tags; pinnedAt = row.pinnedAt; taskID = row.taskID
            createdAt = row.createdAt; updatedAt = row.updatedAt; imageCount = row.imageCount
            fileCount = row.fileCount; firstFileName = row.firstFileName
        }
    }

    /// Keep the actual bytes (including absence), not a re-encoding of a preview.
    struct OpenNote {
        let note: NoteRow, content: Data?, contentFormat: Int, contentFingerprint: String?
        let revision: Int64, revisionID: UUID?

        fileprivate init(_ row: NoteItem) {
            note = NoteRow(row); content = row.content; contentFormat = row.contentFormat
            contentFingerprint = row.contentFingerprint; revision = row.revision; revisionID = row.revisionID
        }
    }

    private let container: ModelContainer
    private let now: () -> Date
    private let save: (ModelContext) throws -> Void

    init(container: ModelContainer, now: @escaping () -> Date = { Date() },
         save: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.container = container; self.now = now; self.save = save
    }

    private func context() -> ModelContext {
        let result = ModelContext(container)
        result.autosaveEnabled = false
        return result
    }

    private func read<Value>(_ query: (ModelContext) throws -> Value) rethrows -> Value {
        let reader = context()
        return try withExtendedLifetime(reader) { try query(reader) }
    }

    private func write<Value>(_ stage: (ModelContext) throws -> Value) throws -> Value {
        let writer = context()
        do {
            let result = try stage(writer)
            if writer.hasChanges { try save(writer) }
            return result
        } catch {
            writer.rollback()
            throw error
        }
    }

    private static func title(_ raw: String) -> String {
        raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func winners<Row>(_ rows: [Row], by id: KeyPath<Row, UUID>,
                                     less: (Row, Row) -> Bool) -> [Row] {
        var found: [UUID: Row] = [:]
        for row in rows {
            let key = row[keyPath: id]
            if let other = found[key], !less(other, row) { continue }
            found[key] = row
        }
        return Array(found.values)
    }

    // Match the Mac stores' tie breakers. Only equal-clock duplicates need these keys.
    private static func taskLess(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
        func bits(_ date: Date?) -> String { date.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "" }
        func key(_ t: TaskItem) -> String {
            var parts = [t.title, t.statusRaw, t.priorityRaw, bits(t.createdAt), bits(t.completedAt)]
            parts += [t.manualOrder.map { String($0) } ?? "", t.parentID?.uuidString ?? "", t.imageReferencesData?.base64EncodedString() ?? ""]
            parts += [bits(t.deletedAt), t.deletionRootID?.uuidString ?? "", t.deletionMembersRaw, t.removedAttachmentsData?.base64EncodedString() ?? ""]
            parts += [bits(t.doneLoggedAt), t.tagsRaw, t.dueDayRaw ?? "", String(reflecting: t.persistentModelID)]
            return parts.joined(separator: "\u{1F}")
        }
        return key(lhs) < key(rhs)
    }

    private static func noteLess(_ lhs: NoteItem, _ rhs: NoteItem) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
        func key(_ n: NoteItem) -> String {
            var parts = [n.title, n.body, String(n.createdAt.timeIntervalSinceReferenceDate.bitPattern),
                         String(n.updatedAt.timeIntervalSinceReferenceDate.bitPattern)]
            parts += [n.deletedAt.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "", n.tagsRaw,
                      String(n.contentFormat), n.revisionID?.uuidString ?? "", String(reflecting: n.persistentModelID)]
            return parts.joined(separator: "\u{1F}")
        }
        return key(lhs) < key(rhs)
    }

    private static func nextClock(_ timestamp: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: timestamp.timeIntervalSinceReferenceDate.nextUp)
    }
}

// MARK: Tasks
extension PhoneLibrary {
    /// Active rows, including subtasks. Resolve UUIDs before applying visibility or status.
    func tasks(status: TaskStatus? = nil) throws -> [TaskRow] {
        try read { reader in
            let rows = try reader.fetch(FetchDescriptor<TaskItem>())
            return Self.winners(rows, by: \.id, less: Self.taskLess).filter {
                $0.deletedAt == nil && $0.doneLoggedAt == nil && (status == nil || $0.listedStatus == status)
            }.map(TaskRow.init).sorted { a, b in
                switch (a.manualOrder, b.manualOrder) {
                case let (x?, y?) where x != y: return x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
                if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
                return a.id.uuidString < b.id.uuidString
            }
        }
    }

    private func taskFamily(_ id: UUID, in context: ModelContext) throws -> ([TaskItem], TaskItem) {
        let rows = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id }))
        guard let shown = rows.max(by: Self.taskLess) else { throw Failure.missingItem }
        guard rows.allSatisfy({ $0.deletedAt == nil && $0.doneLoggedAt == nil }) else { throw Failure.inactiveReplica }
        return (rows, shown)
    }

    // Position a root above existing roots; an edit within the same list keeps its place.
    private func frontOrder(excluding id: UUID, in context: ModelContext) throws -> Int64 {
        let roots = #Predicate<TaskItem> { row in
            (row.parentID == nil && row.id != id) && (row.deletedAt == nil && row.doneLoggedAt == nil)
        }
        // Descending store order puts nil ranks last. If all ranks are nil, start at zero.
        let byRank = SortDescriptor<TaskItem>(\TaskItem.manualOrder, order: .reverse)
        var query = FetchDescriptor<TaskItem>(predicate: roots, sortBy: [byRank])
        query.fetchLimit = 1
        let maximum = try context.fetch(query).first?.manualOrder ?? 0
        let (order, overflow) = maximum.addingReportingOverflow(1024)
        guard !overflow else { throw Failure.orderLimit }
        return order
    }

    @discardableResult
    func createTask(title: String, priority: TaskPriority = .none, status: TaskStatus = .todo,
                    dueDay: DueDay? = nil, dueTimeMinutes: Int? = nil, tags: [String] = []) throws -> TaskRow {
        let clean = Self.title(title)
        guard !clean.isEmpty else { throw Failure.emptyTask }
        if let minutes = dueTimeMinutes, dueDay == nil || !(0..<1440).contains(minutes) { throw Failure.invalidTime }
        return try write { context in
            let timestamp = now()
            let state: TaskStatus = status == .backlog && dueDay != nil ? .todo : status
            let row = TaskItem(title: clean, status: state, priority: priority, createdAt: timestamp,
                               completedAt: state == .done ? timestamp : nil)
            row.manualOrder = try frontOrder(excluding: row.id, in: context)
            row.listOrderVersion = TaskItem.currentListOrderVersion
            row.dueDay = dueDay; row.dueTimeMinutes = dueTimeMinutes; row.tags = tags
            context.insert(row)
            return TaskRow(row)
        }
    }

    /// For day and time, nil means omitted, .some(nil) means explicitly cleared.
    @discardableResult
    func updateTask(id: UUID, patch: MobileTaskEditPatch = .init(title: nil, priority: nil, status: nil),
                    dueDay: DueDay?? = nil, dueTimeMinutes: Int?? = nil, tags: [String]? = nil) throws -> TaskRow {
        let clean = patch.title.map(Self.title)
        if clean?.isEmpty == true { throw Failure.emptyTask }
        return try write { context in
            let (rows, shown) = try taskFamily(id, in: context)
            guard clean != nil || patch.priority != nil || patch.status != nil || dueDay != nil || dueTimeMinutes != nil || tags != nil else {
                return TaskRow(shown)
            }
            let stamp = now(), encodedTags = tags.map { AtticTag.encode($0) }
            var rootOrder: Int64?
            for row in rows {
                let day = dueDay ?? row.dueDay
                var state = patch.status ?? row.listedStatus
                if state == .backlog, case .some(.some) = dueDay { state = .todo }
                let toLater = state == .backlog && patch.status == .backlog
                if let requested = dueTimeMinutes, let minutes = requested, !toLater,
                   day == nil || !(0..<1440).contains(minutes) { throw Failure.invalidTime }
                if state != row.status {
                    try validateTransition(of: row, to: state, in: context)
                    let previousOrder = row.manualOrder
                    if row.parentID == nil && state != row.listedStatus {
                        if rootOrder == nil { rootOrder = try frontOrder(excluding: id, in: context) }
                        row.manualOrder = rootOrder; row.listOrderVersion = TaskItem.currentListOrderVersion
                    }
                    row.completedFromRaw = state == .done ? row.statusRaw : nil
                    row.completedFromOrder = state == .done ? previousOrder : nil
                    row.completedAt = state == .done ? stamp : nil
                    row.status = state
                }
                if let clean, clean != row.title { row.title = clean }
                if let priority = patch.priority, priority != row.priority { row.priority = priority }
                if let encodedTags, encodedTags != row.tagsRaw { row.tagsRaw = encodedTags }
                if toLater || dueDay != nil {
                    let raw = toLater ? nil : day?.rawValue
                    if row.dueDayRaw != raw { row.dueDayRaw = raw }
                    if raw == nil && row.dueTimeMinutesRaw != nil { row.dueTimeMinutesRaw = nil }
                }
                if !toLater, let requested = dueTimeMinutes, row.dueTimeMinutesRaw != requested {
                    row.dueTimeMinutes = requested
                }
            }
            if context.hasChanges {
                shown.updatedAt = max(shown.updatedAt, stamp)
                if rows.contains(where: { $0 !== shown && Self.taskLess(shown, $0) }) {
                    shown.updatedAt = Self.nextClock(shown.updatedAt)
                }
            }
            return TaskRow(shown)
        }
    }

    private func validateTransition(of row: TaskItem, to status: TaskStatus, in context: ModelContext) throws {
        let done = TaskStatus.done.rawValue
        if status == .done {
            let id = row.id
            var unfinished = FetchDescriptor<TaskItem>(predicate: #Predicate {
                $0.parentID == id && $0.deletedAt == nil && $0.statusRaw != done
            })
            unfinished.fetchLimit = 1
            if try !context.fetch(unfinished).isEmpty { throw Failure.taskFamily }
        } else if row.status == .done, let parent = row.parentID {
            let (parents, _) = try taskFamily(parent, in: context)
            if parents.contains(where: { $0.status == .done }) { throw Failure.taskFamily }
        }
    }
}

// MARK: Notes
extension PhoneLibrary {
    func notes() throws -> [NoteRow] {
        try read { reader in
            let rows = try reader.fetch(FetchDescriptor<NoteItem>())
            return Self.winners(rows, by: \.id, less: Self.noteLess).filter { $0.deletedAt == nil }.map(NoteRow.init).sorted { a, b in
                if (a.pinnedAt != nil) != (b.pinnedAt != nil) { return a.pinnedAt != nil }
                if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
                return a.id.uuidString < b.id.uuidString
            }
        }
    }

    private func noteFamily(_ id: UUID, in context: ModelContext) throws -> ([NoteItem], NoteItem) {
        let rows = try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id }))
        guard let shown = rows.max(by: Self.noteLess), shown.deletedAt == nil else { throw Failure.missingItem }
        return (rows, shown)
    }

    func openNote(id: UUID) throws -> OpenNote {
        try read { reader in
            let (_, shown) = try noteFamily(id, in: reader)
            return OpenNote(shown)
        }
    }

    @discardableResult
    func createNote(title: String = "", body: String = "", tags: [String] = [], pinned: Bool = false) throws -> OpenNote {
        let cleanTitle = Self.title(title), cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty || !cleanBody.isEmpty else { throw Failure.emptyNote }
        guard !cleanTitle.contains(NoteDocument.objectCharacter), !cleanBody.contains(NoteDocument.objectCharacter) else {
            throw Failure.readOnlyNote
        }
        return try write { context in
            let stamp = now()
            // The shared constructor creates the native document, digest and search text.
            let row = NoteItem(title: cleanTitle, body: cleanBody, createdAt: stamp)
            row.revision = 1; row.revisionID = UUID(); row.tags = tags; row.pinnedAt = pinned ? stamp : nil
            context.insert(row)
            return OpenNote(row)
        }
    }

    /// Only metadata supplied by the caller is touched; pins/tags are not content revisions.
    @discardableResult
    func updateNoteMetadata(id: UUID, tags: [String]? = nil, pinned: Bool? = nil) throws -> NoteRow {
        try write { context in
            let (rows, shown) = try noteFamily(id, in: context)
            guard rows.allSatisfy({ $0.deletedAt == nil }) else { throw Failure.inactiveReplica }
            if let tags {
                // Task-owned writing has the task's live tags; do not replace legacy note tags.
                guard rows.allSatisfy({ $0.taskID == nil }) else { throw Failure.readOnlyNote }
                let encoded = AtticTag.encode(tags)
                for row in rows where row.tagsRaw != encoded { row.tagsRaw = encoded }
            }
            if let pinned, rows.contains(where: { $0.isPinned != pinned }) {
                let date = pinned ? now() : nil
                for row in rows { row.pinnedAt = date }
            }
            return NoteRow(rows.max(by: Self.noteLess) ?? shown)
        }
    }

    func openDocument(id: UUID) throws -> PhoneNoteDocument {
        try read { reader in
            let (_, shown) = try noteFamily(id, in: reader)
            return PhoneNoteDocument(.init(shown))
        }
    }

    /// Validate every physical copy in the same transaction that installs the patched wire bytes.
    @discardableResult
    func saveDocument(_ opened: PhoneNoteDocument, edits: [PhoneNoteDocument.Edit]) throws -> OpenNote {
        try write { writer in
            let (rows, shown) = try noteFamily(opened.source.noteID, in: writer)
            guard rows.allSatisfy({ $0.deletedAt == nil }) else { throw Failure.inactiveReplica }
            guard rows.allSatisfy({ PhoneNoteDocument.Snapshot($0) == opened.source }) else {
                throw PhoneNoteDocument.Failure.stale
            }
            switch try opened.saving(edits, against: .init(shown)) {
            case .unchanged:
                return OpenNote(shown)
            case let .changed(bytes):
                guard case let .editable(document) = NoteContentCodec.decode(bytes) else { throw Failure.readOnlyNote }
                let stamp = max(now(), shown.updatedAt), token = UUID()
                let title = Self.title(document.title), body = NoteTextExport.plainBody(document)
                let search = NoteTextExport.plainText(document)
                let images = document.blocks.filter { $0.kind == .image }.count
                let files = document.blocks.filter { $0.kind == .file }
                for row in rows {
                    row.content = bytes; row.contentFormat = document.format
                    row.revision = opened.source.revision + 1; row.revisionID = token
                    row.title = title; row.body = body; row.plainText = search
                    row.imageCount = images; row.fileCount = files.count; row.firstFileName = files.first?.filename
                    row.updatedAt = stamp
                }
                if rows.contains(where: { $0 !== shown && Self.noteLess(shown, $0) }) {
                    shown.updatedAt = Self.nextClock(stamp)
                }
                return OpenNote(shown)
            }
        }
    }

    /// Convenience API for the retired phone facade's title/body form. It may
    /// change only unadorned paragraphs. In particular a list preview is never
    /// parsed back into rich writing. Rich editor commands have their own boundary.
    @discardableResult
    func updateNote(_ base: OpenNote, title: String? = nil, body: String? = nil) throws -> OpenNote {
        try write { context in
            let (rows, shown) = try noteFamily(base.note.id, in: context)
            guard rows.allSatisfy({ $0.deletedAt == nil }) else { throw Failure.inactiveReplica }
            // Check actual bytes even for legacy nil fingerprints or reused revision IDs.
            guard rows.allSatisfy({ $0.revision == base.revision && $0.revisionID == base.revisionID &&
                $0.contentFormat == base.contentFormat && $0.content == base.content }) else { throw Failure.staleNote }

            let newTitle: String? = title.flatMap {
                let clean = Self.title($0)
                return NoteTextReplacement.utf16Equal($0, base.note.title) || NoteTextReplacement.utf16Equal(clean, base.note.title) ? nil : clean
            }
            let newBody: String? = body.flatMap { NoteTextReplacement.utf16Equal($0, base.note.body) ? nil : $0 }
            guard newTitle != nil || newBody != nil else { return OpenNote(shown) }
            guard rows.allSatisfy({ $0.taskID == nil }), base.contentFormat == NoteDocument.currentFormat,
                  let raw = base.content, case let .editable(original) = NoteContentCodec.decode(raw),
                  original.extras.isEmpty, original.requires.allSatisfy({ $0 == "text" }),
                  original.blocks.allSatisfy({ $0 == .text($0.text) }) else { throw Failure.readOnlyNote }
            var document = original
            // When a field wasn't edited, retain the native blocks regardless of
            // any disagreement between their text and the old cached projection.
            if let newTitle { document.blocks[0] = .text(newTitle) }
            if let newBody {
                document.blocks.replaceSubrange(1..<document.blocks.count,
                    with: newBody.components(separatedBy: "\n").map { .text($0) })
            }
            // Compare native spelling before encoding: even a legacy projection can
            // be stale, and a semantic no-op must keep the noncanonical original.
            if original.blocks.elementsEqual(document.blocks, by: { NoteTextReplacement.utf16Equal($0.text, $1.text) }) {
                return OpenNote(shown)
            }
            guard !document.isEmpty else { throw Failure.emptyNote }
            guard !document.blocks.contains(where: { $0.text.contains(NoteDocument.objectCharacter) }) else { throw Failure.readOnlyNote }
            let bytes = try NoteContentCodec.encode(document)
            guard base.revision < Int64.max else { throw Failure.revisionLimit }
            let revisionID = UUID(), stamp = max(now(), shown.updatedAt)
            let projectedTitle = Self.title(document.title), projectedBody = NoteTextExport.plainBody(document)
            let searchText = NoteTextExport.plainText(document)
            for row in rows {
                row.content = bytes; row.contentFormat = document.format
                row.revision = base.revision + 1; row.revisionID = revisionID
                row.title = projectedTitle; row.body = projectedBody; row.plainText = searchText
                row.imageCount = 0; row.fileCount = 0; row.firstFileName = nil
                row.updatedAt = stamp
            }
            if rows.contains(where: { $0 !== shown && Self.noteLess(shown, $0) }) {
                shown.updatedAt = Self.nextClock(stamp)
            }
            return OpenNote(shown)
        }
    }
}
