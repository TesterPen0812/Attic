import Foundation
import SwiftData

struct TagCount: Equatable, Sendable {
    let name: String
    /// Live items (tasks, including the Done log; notes; canvases) carrying
    /// the tag, each logical item counted once.
    let count: Int
}

/// The stored tags of every physical row a tag operation changed, so undo
/// can put back exactly what was there, replica by replica.
struct TagChangeSnapshot {
    fileprivate let tagsByRow: [PersistentIdentifier: String]
    var isEmpty: Bool { tagsByRow.isEmpty }
}

enum TagServiceError: LocalizedError {
    case invalidTag(String)

    var errorDescription: String? {
        switch self {
        case let .invalidTag(raw):
            "“\(raw)” is not a valid tag. Use letters, numbers and hyphens."
        }
    }
}

/// Tag management across tasks, notes and canvases: counts, rename, merge
/// and delete. Each operation rewrites every physical row that carries the
/// tag (live, in the Done log or in Recently Deleted, so a restored item
/// comes back with current names) in one save of its own context: it applies
/// everywhere or nowhere. The item stores are refreshed afterwards.
@MainActor
final class TagService {
    private let container: ModelContainer
    private let persist: (ModelContext) throws -> Void
    /// Replaces the item stores' contexts after a successful change.
    var afterChange: () -> Void
    private(set) var lastErrorMessage: String?

    init(
        container: ModelContainer,
        persist: @escaping (ModelContext) throws -> Void = { try $0.save() },
        afterChange: @escaping () -> Void = {}
    ) {
        self.container = container
        self.persist = persist
        self.afterChange = afterChange
    }

    /// Every tag in use on a live item, with how many items carry it, most
    /// used first.
    func counts() -> [TagCount] {
        do {
            var itemsByTag: [String: Set<AtticItemRef>] = [:]
            for (ref, tags) in try liveTags() {
                for tag in tags { itemsByTag[tag, default: []].insert(ref) }
            }
            return itemsByTag
                .map { TagCount(name: $0.key, count: $0.value.count) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        } catch {
            lastErrorMessage = error.localizedDescription
            return []
        }
    }

    /// Live items carrying `tag`.
    func items(taggedWith tag: String) -> Set<AtticItemRef> {
        guard let tag = AtticTag.normalize(tag) else { return [] }
        do {
            return Set(try liveTags().filter { $0.value.contains(tag) }.map(\.key))
        } catch {
            lastErrorMessage = error.localizedDescription
            return []
        }
    }

    /// Renames a tag everywhere. Renaming onto an existing tag merges them.
    func rename(_ tag: String, to newName: String) -> TagChangeSnapshot? {
        merge([tag], into: newName)
    }

    /// Replaces every source tag by `target` on every item that has one.
    func merge(_ sources: [String], into target: String) -> TagChangeSnapshot? {
        guard let target = AtticTag.normalize(target) else {
            lastErrorMessage = TagServiceError.invalidTag(target).localizedDescription
            return nil
        }
        var normalizedSources = Set<String>()
        for source in sources {
            guard let normalized = AtticTag.normalize(source) else {
                lastErrorMessage = TagServiceError.invalidTag(source).localizedDescription
                return nil
            }
            normalizedSources.insert(normalized)
        }
        normalizedSources.remove(target)
        guard !normalizedSources.isEmpty else { return TagChangeSnapshot(tagsByRow: [:]) }
        return rewrite { tags in
            guard !tags.isDisjoint(with: normalizedSources) else { return nil }
            return tags.subtracting(normalizedSources).union([target])
        }
    }

    /// Removes a tag from every item. The items themselves are untouched.
    func delete(_ tag: String) -> TagChangeSnapshot? {
        guard let tag = AtticTag.normalize(tag) else {
            lastErrorMessage = TagServiceError.invalidTag(tag).localizedDescription
            return nil
        }
        return rewrite { tags in
            tags.contains(tag) ? tags.subtracting([tag]) : nil
        }
    }

    /// Puts back the tags a change replaced (undo). Rows that no longer
    /// exist are skipped. Returns false, changing nothing, if the save fails.
    @discardableResult
    func restore(_ snapshot: TagChangeSnapshot) -> Bool {
        guard !snapshot.isEmpty else { return true }
        let context = ModelContext(container)
        for (identifier, raw) in snapshot.tagsByRow {
            switch context.model(for: identifier) {
            case let task as TaskItem: task.tagsRaw = raw
            case let note as NoteItem: note.tagsRaw = raw
            case let board as CanvasBoardItem: board.tagsRaw = raw
            default: continue
            }
        }
        return save(context)
    }

    // MARK: - Private

    /// Applies `transform` to every row's tag set; nil leaves a row alone.
    /// Returns the previous values of the rows it changed.
    private func rewrite(_ transform: (Set<String>) -> Set<String>?) -> TagChangeSnapshot? {
        let context = ModelContext(container)
        var previous: [PersistentIdentifier: String] = [:]
        func apply(_ raw: String, _ identifier: PersistentIdentifier) -> String? {
            guard let changed = transform(Set(AtticTag.decode(raw))) else { return nil }
            let encoded = AtticTag.encode(changed)
            guard encoded != raw else { return nil }
            previous[identifier] = raw
            return encoded
        }
        do {
            for task in try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.tagsRaw != "" })) {
                if let updated = apply(task.tagsRaw, task.persistentModelID) { task.tagsRaw = updated }
            }
            for note in try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.tagsRaw != "" })) {
                if let updated = apply(note.tagsRaw, note.persistentModelID) { note.tagsRaw = updated }
            }
            for board in try context.fetch(FetchDescriptor<CanvasBoardItem>(predicate: #Predicate { $0.tagsRaw != "" })) {
                if let updated = apply(board.tagsRaw, board.persistentModelID) { board.tagsRaw = updated }
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
        guard !previous.isEmpty else { return TagChangeSnapshot(tagsByRow: [:]) }
        guard save(context) else { return nil }
        return TagChangeSnapshot(tagsByRow: previous)
    }

    /// Tags of every live logical item, from the replica presentation would
    /// show (newest `updatedAt`).
    private func liveTags() throws -> [AtticItemRef: Set<String>] {
        let context = ModelContext(container)
        var result: [AtticItemRef: (updatedAt: Date, deleted: Bool, tags: Set<String>)] = [:]
        func consider(_ ref: AtticItemRef, updatedAt: Date, deleted: Bool, raw: String) {
            if let existing = result[ref], existing.updatedAt >= updatedAt { return }
            result[ref] = (updatedAt, deleted, Set(AtticTag.decode(raw)))
        }
        for task in try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.tagsRaw != "" })) {
            consider(AtticItemRef(.task, task.id), updatedAt: task.updatedAt, deleted: task.deletedAt != nil, raw: task.tagsRaw)
        }
        for note in try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.tagsRaw != "" })) {
            consider(AtticItemRef(.note, note.id), updatedAt: note.updatedAt, deleted: note.deletedAt != nil, raw: note.tagsRaw)
        }
        for board in try context.fetch(FetchDescriptor<CanvasBoardItem>(predicate: #Predicate { $0.tagsRaw != "" })) {
            consider(AtticItemRef(.canvas, board.id), updatedAt: board.updatedAt, deleted: board.tombstoned, raw: board.tagsRaw)
        }
        return result.filter { !$0.value.deleted && !$0.value.tags.isEmpty }.mapValues(\.tags)
    }

    private func save(_ context: ModelContext) -> Bool {
        do {
            try persist(context)
            lastErrorMessage = nil
        } catch {
            context.rollback()
            lastErrorMessage = error.localizedDescription
            return false
        }
        afterChange()
        return true
    }
}
