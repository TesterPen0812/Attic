import Foundation
import SwiftData

#if ATTIC_LOCAL_ONLY && !ATTIC_CLOUD_SYNC
/// Local maintenance only. A future sync writer needs its own completed-fetch gate.
@MainActor
struct PhoneDoneCleanup {
    struct Entry: Identifiable {
        let id: UUID
        let parentID: UUID?
        let title: String
        let priority: TaskPriority
        let tags: [String]
        let createdAt: Date
        let updatedAt: Date
        let completedAt: Date?
        let loggedAt: Date
    }

    private let container: ModelContainer
    private let save: (ModelContext) throws -> Void

    init(container: ModelContainer, save: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.container = container
        self.save = save
    }

    static func nextMidnight(after date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        calendar.dateInterval(of: .day, for: date)?.end
    }

    /// Move whole eligible families to history. The result counts distinct task IDs,
    /// including subtasks. A failed read or save throws; an idle pass does not save.
    @discardableResult
    func perform(at date: Date = .now, calendar: Calendar = .autoupdatingCurrent) throws -> Int {
        let writer = ModelContext(container)
        writer.autosaveEnabled = false
        let cutoff = calendar.startOfDay(for: date)
        do {
            let done = TaskStatus.done.rawValue
            let request = FetchDescriptor<TaskItem>(predicate: #Predicate {
                $0.statusRaw == done && $0.deletedAt == nil && $0.doneLoggedAt == nil
            })
            // Compare optional completion dates in Swift: no force-unwrapped store predicate.
            let candidates = Set(try writer.fetch(request).compactMap { row in
                Self.isExpired(row, before: cutoff) ? row.id : nil
            })
            guard !candidates.isEmpty else { return 0 }

            // Discover children by their physical links, then fetch *all* their copies
            // by logical ID. A live or reparented copy can lie outside this predicate.
            var links = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.parentID != nil })
            links.propertiesToFetch = [\.id, \.parentID]
            let children = try writer.fetch(links).compactMap { row -> UUID? in
                guard let parent = row.parentID, candidates.contains(parent) else { return nil }
                return row.id
            }
            let groups = try Self.replicas(of: candidates.union(children), in: writer)
            let moving = Self.eligibleFamilies(in: groups, candidates: candidates, before: cutoff)
            guard !moving.isEmpty else { return 0 }
            for (id, rows) in groups where moving.contains(id) {
                for row in rows { row.doneLoggedAt = date }
            }
            try save(writer)
            return moving.count
        } catch {
            writer.rollback()
            throw error
        }
    }

    /// The flat Mac `doneLog()` view, including children. Like the active phone list,
    /// return values, resolve every copy before filtering, and never reconcile on read.
    func history() throws -> [Entry] {
        let reader = ModelContext(container)
        reader.autosaveEnabled = false
        return try withExtendedLifetime(reader) {
            var request = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.doneLoggedAt != nil })
            request.propertiesToFetch = [\.id]
            let ids = Set(try reader.fetch(request).map(\.id))
            let groups = try Self.replicas(of: ids, in: reader)
            let entries = groups.values.compactMap { copies -> Entry? in
                guard let row = copies.max(by: Self.olderReplica), row.deletedAt == nil,
                      let logged = row.doneLoggedAt else { return nil }
                return Entry(id: row.id, parentID: row.parentID, title: row.title, priority: row.priority,
                             tags: row.tags, createdAt: row.createdAt, updatedAt: row.updatedAt,
                             completedAt: row.completedAt, loggedAt: logged)
            }
            return entries.sorted { left, right in
                let a = left.completedAt ?? left.updatedAt, b = right.completedAt ?? right.updatedAt
                return a != b ? a > b : left.id.uuidString < right.id.uuidString
            }
        }
    }

    /// Read whole replica families in bounded IN queries, including deleted and logged copies.
    private static func replicas(of ids: Set<UUID>, in context: ModelContext) throws -> [UUID: [TaskItem]] {
        let keys = Array(ids), batchSize = 400
        var groups: [UUID: [TaskItem]] = [:]
        for offset in stride(from: 0, to: keys.count, by: batchSize) {
            let batch = Array(keys[offset..<min(offset + batchSize, keys.count)])
            let rows = try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { batch.contains($0.id) }))
            for row in rows { groups[row.id, default: []].append(row) }
        }
        // Absence midway through a read is not evidence that a child was deleted.
        guard groups.count == ids.count else { throw ReadError.incompleteFamilies }
        return groups
    }

    private enum ReadError: LocalizedError {
        case incompleteFamilies
        var errorDescription: String? { "The task family changed while reading the Done log. Try again." }
    }

    private static func isExpired(_ row: TaskItem, before cutoff: Date) -> Bool {
        row.statusRaw == TaskStatus.done.rawValue && row.deletedAt == nil && row.doneLoggedAt == nil &&
            row.completedAt.map { $0 < cutoff } == true
    }

    private static func eligibleFamilies(in groups: [UUID: [TaskItem]], candidates: Set<UUID>,
                                         before cutoff: Date) -> Set<UUID> {
        var moving = Set<UUID>(), neighbours: [UUID: Set<UUID>] = [:]
        for (id, rows) in groups {
            // Only a wholly deleted ID is no longer part of its family. A mixed ID
            // still contributes every link, but cannot itself move.
            guard let first = rows.first, !rows.allSatisfy({ $0.deletedAt != nil }) else { continue }
            if candidates.contains(id), isExpired(first, before: cutoff),
               rows.dropFirst().allSatisfy({ agree(first, $0) }) {
                moving.insert(id)
            }
            for row in rows {
                guard let parent = row.parentID else { continue }
                neighbours[parent, default: []].insert(id)
                neighbours[id, default: []].insert(parent)
            }
        }
        // A missing or ineligible endpoint vetoes its entire connected family,
        // including siblings. Propagate each veto once, independent of fetch order.
        var blocked = neighbours.keys.filter { !moving.contains($0) }
        while let id = blocked.popLast() {
            for relative in neighbours[id] ?? [] where moving.remove(relative) != nil {
                blocked.append(relative)
            }
        }
        return moving
    }

    /// Same fields as the Mac's private TaskReplicaSnapshot in TaskStore.swift.
    /// Use stored values: decoded references and normalized strings can hide disagreements.
    private static func agree(_ a: TaskItem, _ b: TaskItem) -> Bool {
        guard a.id == b.id, NoteTextReplacement.utf16Equal(a.title, b.title),
              a.statusRaw == b.statusRaw, a.priorityRaw == b.priorityRaw,
              a.createdAt == b.createdAt, a.updatedAt == b.updatedAt, a.completedAt == b.completedAt,
              a.manualOrder == b.manualOrder, a.parentID == b.parentID,
              a.imageReferencesData == b.imageReferencesData, a.removedAttachmentsData == b.removedAttachmentsData,
              a.deletedAt == b.deletedAt, a.deletionRootID == b.deletionRootID,
              a.deletionMembersRaw == b.deletionMembersRaw, a.doneLoggedAt == b.doneLoggedAt,
              a.tagsRaw == b.tagsRaw, a.dueDayRaw == b.dueDayRaw, a.dueTimeMinutesRaw == b.dueTimeMinutesRaw,
              a.completedFromRaw == b.completedFromRaw, a.completedFromOrder == b.completedFromOrder else { return false }
        return true
    }

    // Same winner as TaskStore.canonicalReplicas and PhoneLibrary's private taskLess.
    // Only equal-clock physical copies need to materialize the secondary key.
    private static func olderReplica(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
        return tieBreakKey(lhs) < tieBreakKey(rhs)
    }

    private static func tieBreakKey(_ task: TaskItem) -> String {
        func bits(_ date: Date?) -> String { date.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "" }
        var parts = [task.title, task.statusRaw, task.priorityRaw, bits(task.createdAt), bits(task.completedAt)]
        parts += [task.manualOrder.map { String($0) } ?? "", task.parentID?.uuidString ?? "", task.imageReferencesData?.base64EncodedString() ?? ""]
        parts += [bits(task.deletedAt), task.deletionRootID?.uuidString ?? "", task.deletionMembersRaw, task.removedAttachmentsData?.base64EncodedString() ?? ""]
        parts += [bits(task.doneLoggedAt), task.tagsRaw, task.dueDayRaw ?? "", String(reflecting: task.persistentModelID)]
        return parts.joined(separator: "\u{1F}")
    }
}
#endif
