import Combine
import Foundation
import SwiftData

struct TagCount: Equatable, Sendable {
    let name: String
    /// Live items (tasks, including the Done log; notes; canvases) carrying
    /// the tag, each logical item counted once.
    let count: Int
}

/// What a tag operation did to every physical row it changed: the tags it
/// removed and the tags it added, replica by replica. Undo reverses exactly
/// that difference, so tags a row gained or lost since (through any history)
/// are kept.
struct TagChangeSnapshot {
    fileprivate struct Change {
        let removed: Set<String>
        let added: Set<String>
    }

    fileprivate let changesByRow: [PersistentIdentifier: Change]
    var isEmpty: Bool { changesByRow.isEmpty }
    /// How many physical rows the operation changed.
    var rowCount: Int { changesByRow.count }
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
    /// Value-only inventory shared by pickers, shorthand and MCP. Rebuilt only
    /// after tag/membership changes or a fresh external presentation.
    private struct RowState: Hashable {
        let raw: String
        let unavailable: Bool
    }
    private struct Inventory {
        let counts: [TagCount]
        let countsByName: [String: Int]
        let names: [String]
        let rows: [PersistentIdentifier: RowState]
        let divergent: Set<AtticItemRef>
    }
    private var inventory: Inventory?
    private var needsPublication = false
    let inventoryChanges = PassthroughSubject<Void, Never>()
    private(set) var inventoryBuildCount = 0
    private(set) var inventoryFetchCount = 0
    private(set) var inventoryRowReadCount = 0

    var names: [String] { _ = counts(); return inventory?.names ?? [] }
    var countsByName: [String: Int] { _ = counts(); return inventory?.countsByName ?? [:] }

    /// Inspect only rows touched by this transaction, never the whole store.
    /// Divergent replicas can change the winning tag set through a content
    /// edit, so those identities also invalidate when any replica changes.
    func invalidate(in context: ModelContext) {
        guard let inventory else { return }
        func state(_ model: any PersistentModel) -> (AtticItemRef, RowState)? {
            switch model {
            case let task as TaskItem:
                return (AtticItemRef(.task, task.id), RowState(raw: task.tagsRaw, unavailable: task.deletedAt != nil))
            case let note as NoteItem:
                return (AtticItemRef(.note, note.id), RowState(raw: note.tagsRaw, unavailable: note.deletedAt != nil))
            case let board as CanvasBoardItem:
                return (AtticItemRef(.canvas, board.id), RowState(raw: board.tagsRaw, unavailable: board.tombstoned || board.purgedAt != nil))
            default: return nil
            }
        }
        for model in context.insertedModelsArray + context.deletedModelsArray where state(model) != nil {
            invalidateInventory(publish: false)
            return
        }
        for model in context.changedModelsArray {
            guard let (ref, current) = state(model) else { continue }
            let previous = inventory.rows[model.persistentModelID] ?? RowState(raw: "", unavailable: current.unavailable)
            if previous != current || inventory.divergent.contains(ref) {
                invalidateInventory(publish: false)
                return
            }
        }
    }

    /// Called after persistence (or rollback), so observers never warm a cache
    /// with an uncommitted tag set. Fresh external contexts invalidate outright.
    func publishInventoryChange() {
        guard needsPublication else { return }
        needsPublication = false
        inventoryChanges.send()
    }

    func invalidateInventory(publish: Bool = true) {
        inventory = nil
        needsPublication = true
        if publish { publishInventoryChange() }
    }

    private let container: ModelContainer
    private var writerCoordinator: WorkspaceOperationCoordinator?
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
        self.writerCoordinator = try? WorkspaceLegacyBridge.coordinator(for: container)
        self.afterChange = afterChange
    }

    /// Every tag in use on a live item, with how many items carry it, most
    /// used first.
    func counts() -> [TagCount] {
        if let inventory { return inventory.counts }
        do {
            var rows: [PersistentIdentifier: RowState] = [:]
            var divergent = Set<AtticItemRef>()
            var itemsByTag: [String: Set<AtticItemRef>] = [:]
            for (ref, tags) in try liveTags(rows: &rows, divergent: &divergent) {
                for tag in tags { itemsByTag[tag, default: []].insert(ref) }
            }
            let counts = itemsByTag
                .map { TagCount(name: $0.key, count: $0.value.count) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
            inventory = Inventory(counts: counts, countsByName: Dictionary(uniqueKeysWithValues: counts.map { ($0.name, $0.count) }),
                                  names: counts.map(\.name), rows: rows, divergent: divergent)
            inventoryBuildCount += 1
            return counts
        } catch {
            lastErrorMessage = error.localizedDescription
            return []
        }
    }

    /// Live items carrying `tag`.
    func items(taggedWith tag: String) -> Set<AtticItemRef> {
        guard let tag = AtticTag.normalize(tag) else { return [] }
        do {
            var rows: [PersistentIdentifier: RowState] = [:]
            var divergent = Set<AtticItemRef>()
            return Set(try liveTags(rows: &rows, divergent: &divergent).filter { $0.value.contains(tag) }.map(\.key))
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
        guard !normalizedSources.isEmpty else { return TagChangeSnapshot(changesByRow: [:]) }
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

    /// Reverses a change (undo): on each row it changed, the tags it added
    /// are removed and the tags it removed come back; every other tag the
    /// row holds now stays. Rows that no longer exist are skipped. Returns
    /// false, changing nothing, if the save fails.
    @discardableResult
    func revert(_ snapshot: TagChangeSnapshot) -> Bool {
        guard !snapshot.isEmpty else { return true }
        let context = WorkspaceLegacyBridge.context(for: container, includeCanvas: true)
        var changed = false
        func reverted(_ raw: String, _ change: TagChangeSnapshot.Change) -> String? {
            let tags = Set(AtticTag.decode(raw)).subtracting(change.added).union(change.removed)
            let encoded = AtticTag.encode(tags)
            guard encoded != raw else { return nil }
            changed = true
            return encoded
        }
        for (identifier, change) in snapshot.changesByRow {
            switch context.model(for: identifier) {
            case let task as TaskItem:
                if let raw = reverted(task.tagsRaw, change) { WorkspaceLegacyBridge.prepareMutation(task, in: context); task.tagsRaw = raw }
            case let note as NoteItem:
                if let raw = reverted(note.tagsRaw, change) { WorkspaceLegacyBridge.prepareMutation(note, in: context); note.tagsRaw = raw }
            case let board as CanvasBoardItem:
                if let raw = reverted(board.tagsRaw, change) { WorkspaceLegacyBridge.prepareMutation(board, in: context); board.tagsRaw = raw }
            default: continue
            }
        }
        guard changed else { return true }
        return save(context)
    }

    // MARK: - Private

    /// Applies `transform` to every row's tag set; nil leaves a row alone.
    /// Returns what it removed and added on each row it changed.
    private func rewrite(_ transform: (Set<String>) -> Set<String>?) -> TagChangeSnapshot? {
        let context = WorkspaceLegacyBridge.context(for: container, includeCanvas: true)
        var previous: [PersistentIdentifier: TagChangeSnapshot.Change] = [:]
        func apply(_ raw: String, _ identifier: PersistentIdentifier) -> String? {
            let before = Set(AtticTag.decode(raw))
            guard let changed = transform(before) else { return nil }
            let encoded = AtticTag.encode(changed)
            guard encoded != raw else { return nil }
            let after = Set(AtticTag.decode(encoded))
            previous[identifier] = .init(removed: before.subtracting(after), added: after.subtracting(before))
            return encoded
        }
        do {
            for task in try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.tagsRaw != "" })) {
                if let updated = apply(task.tagsRaw, task.persistentModelID) { WorkspaceLegacyBridge.prepareMutation(task, in: context); task.tagsRaw = updated }
            }
            for note in try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.tagsRaw != "" })) {
                if let updated = apply(note.tagsRaw, note.persistentModelID) { WorkspaceLegacyBridge.prepareMutation(note, in: context); note.tagsRaw = updated }
            }
            for board in try context.fetch(FetchDescriptor<CanvasBoardItem>(predicate: #Predicate { $0.tagsRaw != "" })) {
                if let updated = apply(board.tagsRaw, board.persistentModelID) { WorkspaceLegacyBridge.prepareMutation(board, in: context); board.tagsRaw = updated }
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
        guard !previous.isEmpty else { return TagChangeSnapshot(changesByRow: [:]) }
        guard save(context) else { return nil }
        return TagChangeSnapshot(changesByRow: previous)
    }

    /// Tags of every live logical item, from the replica presentation shows.
    /// Candidates are the ids with any tagged row; every replica of each is
    /// then resolved (`canonicalReplicas`, the canvas winner) before the
    /// live and tag filters, so an older tagged copy never answers for a
    /// newer one that has no tags or is deleted.
    private func liveTags(rows metadata: inout [PersistentIdentifier: RowState],
                          divergent: inout Set<AtticItemRef>) throws -> [AtticItemRef: Set<String>] {
        let context = ModelContext(container)
        var result: [AtticItemRef: Set<String>] = [:]
        var firstState: [AtticItemRef: RowState] = [:]
        func remember(_ identifier: PersistentIdentifier, _ ref: AtticItemRef, _ raw: String, _ unavailable: Bool) {
            let state = RowState(raw: raw, unavailable: unavailable)
            metadata[identifier] = state
            if let first = firstState[ref], first != state { divergent.insert(ref) }
            firstState[ref] = state
            inventoryRowReadCount += 1
        }
        func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> [T] {
            inventoryFetchCount += 1
            return try context.fetch(descriptor)
        }
        func record(_ ref: AtticItemRef, _ raw: String) {
            let tags = Set(AtticTag.decode(raw))
            if !tags.isEmpty { result[ref] = tags }
        }

        let taskIDs = Array(Set(try fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.tagsRaw != "" }
        )).map(\.id)))
        if !taskIDs.isEmpty {
            let rows = try fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { taskIDs.contains($0.id) }))
            for task in rows { remember(task.persistentModelID, AtticItemRef(.task, task.id), task.tagsRaw, task.deletedAt != nil) }
            for task in TaskStore.canonicalReplicas(from: rows) where task.deletedAt == nil {
                record(AtticItemRef(.task, task.id), task.tagsRaw)
            }
        }

        let noteIDs = Array(Set(try fetch(FetchDescriptor<NoteItem>(
            predicate: #Predicate { $0.tagsRaw != "" }
        )).map(\.id)))
        if !noteIDs.isEmpty {
            let rows = try fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { noteIDs.contains($0.id) }))
            for note in rows { remember(note.persistentModelID, AtticItemRef(.note, note.id), note.tagsRaw, note.deletedAt != nil) }
            for note in NoteStore.canonicalReplicas(from: rows) where note.deletedAt == nil {
                record(AtticItemRef(.note, note.id), note.tagsRaw)
            }
        }

        let boardIDs = Array(Set(try fetch(FetchDescriptor<CanvasBoardItem>(
            predicate: #Predicate { $0.tagsRaw != "" }
        )).map(\.id)))
        if !boardIDs.isEmpty {
            let rows = try fetch(FetchDescriptor<CanvasBoardItem>(
                predicate: #Predicate { boardIDs.contains($0.id) }
            ))
            for board in rows { remember(board.persistentModelID, AtticItemRef(.canvas, board.id), board.tagsRaw, board.tombstoned || board.purgedAt != nil) }
            for replicas in Dictionary(grouping: rows, by: \.id).values {
                let board = CanvasStore.winningBoardReplica(in: replicas)
                guard !board.tombstoned, board.purgedAt == nil else { continue }
                record(AtticItemRef(.canvas, board.id), board.tagsRaw)
            }
        }
        return result
    }

    private func save(_ context: ModelContext) -> Bool {
        invalidate(in: context)
        do {
            try WorkspaceLegacyBridge.persist(context, using: persist, sourceName: "TagService")
            publishInventoryChange()
            lastErrorMessage = nil
        } catch {
            context.rollback()
            invalidateInventory()
            lastErrorMessage = error.localizedDescription
            return false
        }
        afterChange()
        return true
    }
}
