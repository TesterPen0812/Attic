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
    var affectedItems: Set<AtticItemRef> = []
    var isEmpty: Bool { changesByRow.isEmpty }
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
    /// Value-only inventory shared by pickers, shorthand, chips, colours and
    /// MCP. The model keeps it current: it is built once (`prepare`), then
    /// patched after each durable save from the saved rows of the items the
    /// save touched, and reconciled from the rows a store reload has already
    /// read. No reader builds it. A full build is left only for what cannot
    /// be patched (a failed patch or reload, an explicit refresh), and the
    /// model does it at that point.
    private struct RowState: Hashable {
        let raw: String
        let unavailable: Bool
        let created: Date
    }
    /// What a live logical item adds to the inventory: its winning replica's
    /// tags and creation date.
    private struct Item: Equatable {
        let tags: Set<String>
        let created: Date
    }
    private struct Inventory {
        /// Every physical row of every item with a tagged row (live, deleted
        /// or in the Done log), so a change to any replica is seen.
        var rows: [PersistentIdentifier: RowState] = [:]
        var refRows: [AtticItemRef: Set<PersistentIdentifier>] = [:]
        var items: [AtticItemRef: Item] = [:]
        var itemsByTag: [String: Set<AtticItemRef>] = [:]
        var firstUse: [String: Date] = [:]
        /// Items whose replicas disagree: any change to them is re-read,
        /// since a content edit can change which replica wins.
        var divergent: Set<AtticItemRef> = []
        var counts: [TagCount] = []
        var countsByName: [String: Int] = [:]
        var names: [String] = []
        /// Tags in use by when they were first used (the oldest item that
        /// carries them), then by name: the order new colours are given in.
        var oldestFirst: [String] = []
    }
    private var inventory: Inventory?
    private var inventoryBuildFailed = false
    /// Items a save in progress touched, by kind; patched once it is durable.
    private var pending: [AtticItemKind: Set<UUID>] = [:]
    /// The save in progress began with no inventory (a failed build): the
    /// model makes its one fresh attempt once that save is durable.
    private var rebuildAfterSave = false
    let inventoryChanges = PassthroughSubject<Void, Never>()
    /// A rename or merge that changed items: its sources now read `target`
    /// (the Tasks panel's tag chip follows the chosen tag).
    let renames = PassthroughSubject<(sources: Set<String>, target: String), Never>()
    /// Full builds (a fetch of every tagged row). Readers never add to it.
    private(set) var inventoryBuildCount = 0
    private(set) var inventoryFetchCount = 0
    private(set) var inventoryRowReadCount = 0

    var names: [String] { _ = counts(); return inventory?.names ?? [] }
    var countsByName: [String: Int] { _ = counts(); return inventory?.countsByName ?? [:] }
    /// Tags in use, oldest first (`TagColourStore` gives colours in this order).
    var namesOldestFirst: [String] { _ = counts(); return inventory?.oldestFirst ?? [] }
    /// Run inside a rename or merge's own save, before it: carries the
    /// sources' colour to the target in the same context, so the colour and
    /// the tags change together or not at all (`TagColourStore.carry`).
    var carryColour: (@MainActor (_ sources: [String], _ target: String, _ targetInUse: Bool, _ inUse: [String], _ context: ModelContext) throws -> Void)?

    /// Builds the inventory now, so that no reader ever has to. The library
    /// calls it once it has wired its stores.
    func prepare() {
        _ = counts()
    }

    /// Before a save: notes which items the transaction touches in a way the
    /// inventory can see (a row inserted or deleted, its tags, whether it is
    /// deleted, its creation date, or any change to an item whose replicas
    /// disagree). Content-only edits of an item with one replica touch
    /// nothing. Nothing is applied until the save is durable.
    func invalidate(in context: ModelContext) {
        guard let inventory else {
            // A failed build has no row metadata to compare. The next durable
            // save permits one fresh attempt, just like a refresh.
            rebuildAfterSave = true
            return
        }
        func consider(_ model: any PersistentModel, removed: Bool) {
            guard let (kind, id, state) = describe(model) else { return }
            let ref = AtticItemRef(kind, id)
            if let known = inventory.refRows[ref] {
                if removed || known.count > 1 || inventory.divergent.contains(ref)
                    || inventory.rows[model.persistentModelID] != state {
                    pending[kind, default: []].insert(id)
                }
            } else if !removed, !state.raw.isEmpty {
                pending[kind, default: []].insert(id)
            }
        }
        for model in context.insertedModelsArray { consider(model, removed: false) }
        for model in context.changedModelsArray { consider(model, removed: false) }
        for model in context.deletedModelsArray { consider(model, removed: true) }
    }

    /// After a durable save (or rollback-free completion): patches the items
    /// the save touched from their saved rows, and publishes only if the tags
    /// in use, their counts or their order changed.
    func publishInventoryChange() {
        if rebuildAfterSave {
            rebuildAfterSave = false
            pending = [:]
            rebuild()
            return
        }
        guard !pending.isEmpty else { return }
        let touched = pending
        pending = [:]
        guard inventory != nil else { return }
        do {
            try patch(touched)
        } catch {
            // The saved rows could not be read: the model builds again here,
            // never the first reader.
            rebuild()
        }
    }

    /// A save failed and was rolled back: what it touched never happened.
    func discardPending() {
        pending = [:]
        rebuildAfterSave = false
    }

    /// An explicit refresh: the model builds the inventory again now, and
    /// publishes if it differs. Also the one fresh attempt after a failure.
    func invalidateInventory(publish: Bool = true) {
        pending = [:]
        rebuildAfterSave = false
        rebuild(publish: publish)
    }

    /// The task store reloaded: reconcile from every task row it read.
    /// `nil` means the reload failed, so the model builds again.
    func reconcile(tasks rows: [TaskItem]?) {
        guard let rows else { return invalidateInventory() }
        reconcile(.task, rows, describe: { ($0.persistentModelID, $0.id, Self.state(of: $0)) }, winner: { replicas in
            TaskStore.canonicalReplicas(from: replicas).first.flatMap { $0.deletedAt == nil ? Self.item($0.tagsRaw, $0.createdAt) : nil }
        })
    }

    /// The note store reloaded: reconcile from every note row it read.
    func reconcile(notes rows: [NoteItem]?) {
        guard let rows else { return invalidateInventory() }
        reconcile(.note, rows, describe: { ($0.persistentModelID, $0.id, Self.state(of: $0)) }, winner: { replicas in
            NoteStore.canonicalReplicas(from: replicas).first.flatMap { $0.deletedAt == nil ? Self.item($0.tagsRaw, $0.createdAt) : nil }
        })
    }

    /// The old Canvas store reloaded. Its rows are left unread while Draw has
    /// Canvas's place; otherwise every board row is read again (there are few).
    func reconcileBoards() {
        guard !AtticLegacyCanvas.isDormant(container) else { return }
        do {
            inventoryFetchCount += 1
            let rows = try ModelContext(container).fetchCanvasReplicas(FetchDescriptor<CanvasBoardItem>())
            reconcile(.canvas, rows, describe: { ($0.persistentModelID, $0.id, Self.state(of: $0)) }, winner: Self.boardItem)
        } catch {
            invalidateInventory()
        }
    }

    private let container: ModelContainer
    private var writerCoordinator: WorkspaceOperationCoordinator?
    private let persist: (ModelContext) throws -> Void
    private let fetchTaggedTasks: (ModelContext) throws -> [TaskItem]
    /// Replaces the item stores' contexts after a successful change.
    var afterChange: () -> Void
    private(set) var lastErrorMessage: String?

    init(
        container: ModelContainer,
        persist: @escaping (ModelContext) throws -> Void = { try $0.save() },
        fetchTaggedTasks: @escaping (ModelContext) throws -> [TaskItem] = {
            try $0.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.tagsRaw != "" }))
        },
        afterChange: @escaping () -> Void = {}
    ) {
        self.container = container
        self.persist = persist
        self.writerCoordinator = try? WorkspaceLegacyBridge.coordinator(for: container)
        self.fetchTaggedTasks = fetchTaggedTasks
        self.afterChange = afterChange
    }

    /// Every tag in use on a live item, with how many items carry it, most
    /// used first. Builds only if the inventory was never built (a service
    /// used on its own); after a failed build it answers empty until the
    /// model tries again.
    func counts() -> [TagCount] {
        if let inventory { return inventory.counts }
        guard !inventoryBuildFailed else { return [] }
        do {
            inventory = try build()
            inventoryBuildCount += 1
            return inventory?.counts ?? []
        } catch {
            inventoryBuildFailed = true
            lastErrorMessage = error.localizedDescription
            return []
        }
    }

    /// Live items carrying `tag`.
    func items(taggedWith tag: String) -> Set<AtticItemRef> {
        guard let tag = AtticTag.normalize(tag) else { return [] }
        do {
            return Set(try liveTagSets().tags.filter { $0.value.contains(tag) }.map(\.key))
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
        let carry = carryColour
        let sourceOrder = sources.compactMap(AtticTag.normalize).filter { normalizedSources.contains($0) }
        let snapshot = rewrite(beforeRewrite: { context in
            let (live, firstUse) = try self.liveTagSets(in: context)
            let targetInUse = live.values.contains { $0.contains(target) }
            let inUse = firstUse.keys.sorted {
                let a = firstUse[$0]!, b = firstUse[$1]!
                return a != b ? a < b : $0 < $1
            }
            try carry?(sourceOrder, target, targetInUse, inUse, context)
        }) { tags in
            guard !tags.isDisjoint(with: normalizedSources) else { return nil }
            return tags.subtracting(normalizedSources).union([target])
        }
        if let snapshot, !snapshot.isEmpty { renames.send((normalizedSources, target)) }
        return snapshot
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
    private func rewrite(beforeRewrite: (ModelContext) throws -> Void = { _ in },
                         _ transform: (Set<String>) -> Set<String>?) -> TagChangeSnapshot? {
        let context = WorkspaceLegacyBridge.context(for: container, includeCanvas: true)
        var previous: [PersistentIdentifier: TagChangeSnapshot.Change] = [:]
        var affectedItems = Set<AtticItemRef>()
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
            try beforeRewrite(context)
            for task in try context.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.tagsRaw != "" })) {
                if let updated = apply(task.tagsRaw, task.persistentModelID) {
                    WorkspaceLegacyBridge.prepareMutation(task, in: context)
                    task.tagsRaw = updated
                    affectedItems.insert(AtticItemRef(.task, task.id))
                }
            }
            for note in try context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.tagsRaw != "" })) {
                if let updated = apply(note.tagsRaw, note.persistentModelID) {
                    WorkspaceLegacyBridge.prepareMutation(note, in: context)
                    note.tagsRaw = updated
                    affectedItems.insert(AtticItemRef(.note, note.id))
                }
            }
            // While Draw has Canvas's place the old boards are left unread.
            let boards: [CanvasBoardItem] = try AtticLegacyCanvas.isDormant(context) ? []
                : context.fetchCanvasReplicas(FetchDescriptor<CanvasBoardItem>(predicate: #Predicate { $0.tagsRaw != "" }))
            for board in boards {
                if let updated = apply(board.tagsRaw, board.persistentModelID) {
                    WorkspaceLegacyBridge.prepareMutation(board, in: context)
                    board.tagsRaw = updated
                    affectedItems.insert(AtticItemRef(.canvas, board.id))
                }
            }
        } catch {
            context.rollback()
            lastErrorMessage = error.localizedDescription
            return nil
        }
        guard !previous.isEmpty else { return TagChangeSnapshot(changesByRow: [:]) }
        guard save(context) else { return nil }
        return TagChangeSnapshot(changesByRow: previous, affectedItems: affectedItems)
    }


    // MARK: - Keeping the inventory

    private static func state(of task: TaskItem) -> RowState {
        RowState(raw: task.tagsRaw, unavailable: task.deletedAt != nil, created: task.createdAt)
    }

    private static func state(of note: NoteItem) -> RowState {
        RowState(raw: note.tagsRaw, unavailable: note.deletedAt != nil, created: note.createdAt)
    }

    private static func state(of board: CanvasBoardItem) -> RowState {
        RowState(raw: board.tagsRaw, unavailable: board.tombstoned || board.purgedAt != nil, created: board.createdAt)
    }

    private static func item(_ raw: String, _ created: Date) -> Item? {
        let tags = Set(AtticTag.decode(raw))
        return tags.isEmpty ? nil : Item(tags: tags, created: created)
    }

    private static func boardItem(_ replicas: [CanvasBoardItem]) -> Item? {
        guard !replicas.isEmpty else { return nil }
        let board = CanvasStore.winningBoardReplica(in: replicas)
        guard !board.tombstoned, board.purgedAt == nil else { return nil }
        return item(board.tagsRaw, board.createdAt)
    }

    /// The kind, item id and inventory-relevant state of a row, or nil for a
    /// row the inventory does not hold (old Canvas rows while Draw is on).
    private func describe(_ model: any PersistentModel) -> (AtticItemKind, UUID, RowState)? {
        switch model {
        case let task as TaskItem: return (.task, task.id, Self.state(of: task))
        case let note as NoteItem: return (.note, note.id, Self.state(of: note))
        case let board as CanvasBoardItem:
            guard !AtticLegacyCanvas.isDormant(container) else { return nil }
            return (.canvas, board.id, Self.state(of: board))
        default: return nil
        }
    }

    /// Reads every tagged item from scratch. Only `counts()` calls it.
    private func build() throws -> Inventory {
        var next = Inventory()
        var touched = Set<String>()
        let context = ModelContext(container)
        inventoryFetchCount += 1
        let taskIDs = Array(Set(try fetchTaggedTasks(context).map(\.id)))
        if !taskIDs.isEmpty {
            let rows = try fetchRows(FetchDescriptor<TaskItem>(predicate: #Predicate { taskIDs.contains($0.id) }), in: context)
            apply(.task, rows, ids: Set(taskIDs), describe: { ($0.persistentModelID, $0.id, Self.state(of: $0)) },
                  winner: { TaskStore.canonicalReplicas(from: $0).first.flatMap { $0.deletedAt == nil ? Self.item($0.tagsRaw, $0.createdAt) : nil } },
                  to: &next, touched: &touched)
        }
        let noteIDs = Array(Set(try fetchRows(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.tagsRaw != "" }), in: context, counted: false).map(\.id)))
        if !noteIDs.isEmpty {
            let rows = try fetchRows(FetchDescriptor<NoteItem>(predicate: #Predicate { noteIDs.contains($0.id) }), in: context)
            apply(.note, rows, ids: Set(noteIDs), describe: { ($0.persistentModelID, $0.id, Self.state(of: $0)) },
                  winner: { NoteStore.canonicalReplicas(from: $0).first.flatMap { $0.deletedAt == nil ? Self.item($0.tagsRaw, $0.createdAt) : nil } },
                  to: &next, touched: &touched)
        }
        if !AtticLegacyCanvas.isDormant(container) {
            let boardIDs = Array(Set(try fetchRows(FetchDescriptor<CanvasBoardItem>(predicate: #Predicate { $0.tagsRaw != "" }), in: context, counted: false).map(\.id)))
            if !boardIDs.isEmpty {
                let rows = try fetchRows(FetchDescriptor<CanvasBoardItem>(predicate: #Predicate { boardIDs.contains($0.id) }), in: context)
                apply(.canvas, rows, ids: Set(boardIDs), describe: { ($0.persistentModelID, $0.id, Self.state(of: $0)) },
                      winner: Self.boardItem, to: &next, touched: &touched)
            }
        }
        Self.finish(&next, touched: touched)
        return next
    }

    /// After a durable save: reads every replica of the touched items from
    /// the store and puts them in place of what the inventory held for them.
    private func patch(_ touched: [AtticItemKind: Set<UUID>]) throws {
        guard var next = inventory else { return }
        var tags = Set<String>()
        let context = ModelContext(container)
        if let ids = touched[.task], !ids.isEmpty {
            let list = Array(ids)
            let rows = try fetchRows(FetchDescriptor<TaskItem>(predicate: #Predicate { list.contains($0.id) }), in: context)
            apply(.task, rows, ids: ids, describe: { ($0.persistentModelID, $0.id, Self.state(of: $0)) },
                  winner: { TaskStore.canonicalReplicas(from: $0).first.flatMap { $0.deletedAt == nil ? Self.item($0.tagsRaw, $0.createdAt) : nil } },
                  to: &next, touched: &tags)
        }
        if let ids = touched[.note], !ids.isEmpty {
            let list = Array(ids)
            let rows = try fetchRows(FetchDescriptor<NoteItem>(predicate: #Predicate { list.contains($0.id) }), in: context)
            apply(.note, rows, ids: ids, describe: { ($0.persistentModelID, $0.id, Self.state(of: $0)) },
                  winner: { NoteStore.canonicalReplicas(from: $0).first.flatMap { $0.deletedAt == nil ? Self.item($0.tagsRaw, $0.createdAt) : nil } },
                  to: &next, touched: &tags)
        }
        if let ids = touched[.canvas], !ids.isEmpty, !AtticLegacyCanvas.isDormant(container) {
            let list = Array(ids)
            let rows = try fetchRows(FetchDescriptor<CanvasBoardItem>(predicate: #Predicate { list.contains($0.id) }), in: context)
            apply(.canvas, rows, ids: ids, describe: { ($0.persistentModelID, $0.id, Self.state(of: $0)) },
                  winner: Self.boardItem, to: &next, touched: &tags)
        }
        install(next, touched: tags)
    }

    /// A store reload read every row of one kind: the items whose rows differ
    /// from what the inventory holds (or that newly carry a tag, or whose
    /// replicas disagree) are put in place from those rows. Nothing is read
    /// again from the store.
    private func reconcile<T: PersistentModel>(_ kind: AtticItemKind, _ rows: [T],
                                                describe: (T) -> (PersistentIdentifier, UUID, RowState),
                                                winner: ([T]) -> Item?) {
        pending[kind] = nil
        guard let current = inventory else { return rebuild() }
        var affected = Set<UUID>()
        var seen = Set<PersistentIdentifier>()
        for row in rows {
            let (identifier, id, state) = describe(row)
            seen.insert(identifier)
            let ref = AtticItemRef(kind, id)
            if let known = current.refRows[ref] {
                if known.count > 1 || current.divergent.contains(ref) || current.rows[identifier] != state { affected.insert(id) }
            } else if !state.raw.isEmpty {
                affected.insert(id)
            }
        }
        for (ref, identifiers) in current.refRows where ref.kind == kind && !identifiers.isSubset(of: seen) {
            affected.insert(ref.id)
        }
        guard !affected.isEmpty else { return }
        var next = current
        var tags = Set<String>()
        apply(kind, rows.filter { affected.contains(describe($0).1) }, ids: affected, describe: describe, winner: winner,
              to: &next, touched: &tags)
        install(next, touched: tags)
    }

    /// Puts each item in `ids` in place from `rows` (every replica of it the
    /// store holds; none if it is gone).
    private func apply<T: PersistentModel>(_ kind: AtticItemKind, _ rows: [T], ids: Set<UUID>,
                                           describe: (T) -> (PersistentIdentifier, UUID, RowState),
                                           winner: ([T]) -> Item?,
                                           to inventory: inout Inventory, touched: inout Set<String>) {
        var replicasByID: [UUID: [T]] = [:]
        for row in rows { replicasByID[describe(row).1, default: []].append(row) }
        for id in ids {
            let ref = AtticItemRef(kind, id)
            let replicas = replicasByID[id] ?? []
            for identifier in inventory.refRows[ref] ?? [] { inventory.rows[identifier] = nil }
            let states = replicas.map { (describe($0).0, describe($0).2) }
            if states.contains(where: { !$0.1.raw.isEmpty }) {
                inventory.refRows[ref] = Set(states.map { $0.0 })
                for (identifier, state) in states { inventory.rows[identifier] = state }
                if Set(states.map { $0.1 }).count > 1 { inventory.divergent.insert(ref) } else { inventory.divergent.remove(ref) }
            } else {
                inventory.refRows[ref] = nil
                inventory.divergent.remove(ref)
            }
            let next = inventory.refRows[ref] == nil ? nil : winner(replicas)
            let previous = inventory.items[ref]
            guard next != previous else { continue }
            for tag in previous?.tags ?? [] { inventory.itemsByTag[tag]?.remove(ref); touched.insert(tag) }
            for tag in next?.tags ?? [] { inventory.itemsByTag[tag, default: []].insert(ref); touched.insert(tag) }
            inventory.items[ref] = next
        }
    }

    /// Recomputes what readers see for the tags whose items changed.
    private static func finish(_ inventory: inout Inventory, touched: Set<String>) {
        guard !touched.isEmpty else { return }
        for tag in touched {
            let refs = inventory.itemsByTag[tag] ?? []
            if refs.isEmpty {
                inventory.itemsByTag[tag] = nil
                inventory.firstUse[tag] = nil
            } else {
                inventory.firstUse[tag] = refs.compactMap { inventory.items[$0]?.created }.min()
            }
        }
        let counts = inventory.itemsByTag
            .map { TagCount(name: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        inventory.counts = counts
        inventory.countsByName = Dictionary(uniqueKeysWithValues: counts.map { ($0.name, $0.count) })
        inventory.names = counts.map(\.name)
        inventory.oldestFirst = counts.map(\.name).sorted {
            let (a, b) = (inventory.firstUse[$0] ?? .distantFuture, inventory.firstUse[$1] ?? .distantFuture)
            return a != b ? a < b : $0 < $1
        }
    }

    /// Installs a patched inventory and publishes only a change readers see.
    private func install(_ next: Inventory, touched: Set<String>) {
        var next = next
        Self.finish(&next, touched: touched)
        let changed = next.counts != inventory?.counts || next.oldestFirst != inventory?.oldestFirst
        inventory = next
        if changed { inventoryChanges.send() }
    }

    /// Builds from scratch, here and now; publishes if readers would see a
    /// difference. A failure leaves the inventory empty until the next try.
    private func rebuild(publish: Bool = true) {
        let previous = inventory
        inventory = nil
        inventoryBuildFailed = false
        _ = counts()
        guard publish else { return }
        if previous?.counts != inventory?.counts || previous?.oldestFirst != inventory?.oldestFirst || (previous == nil) != (inventory == nil) {
            inventoryChanges.send()
        }
    }

    private func fetchRows<T: PersistentModel>(_ descriptor: FetchDescriptor<T>, in context: ModelContext, counted: Bool = true) throws -> [T] {
        inventoryFetchCount += 1
        // Old Canvas rows go through the counted, gated funnel.
        let rows = T.self == CanvasBoardItem.self ? try context.fetchCanvasReplicas(descriptor) : try context.fetch(descriptor)
        if counted { inventoryRowReadCount += rows.count }
        return rows
    }

    /// Tags of every live logical item in `context` (a rename or merge's own
    /// transaction reads them before it writes), with when each tag was
    /// first used. Not the shared inventory.
    private func liveTagSets(in suppliedContext: ModelContext? = nil) throws -> (tags: [AtticItemRef: Set<String>], firstUse: [String: Date]) {
        let context = suppliedContext ?? ModelContext(container)
        var result: [AtticItemRef: Set<String>] = [:]
        var firstUse: [String: Date] = [:]
        func record(_ ref: AtticItemRef, _ item: Item?) {
            guard let item else { return }
            result[ref] = item.tags
            for tag in item.tags where item.created < firstUse[tag] ?? .distantFuture { firstUse[tag] = item.created }
        }
        inventoryFetchCount += 1
        let taskIDs = Array(Set(try fetchTaggedTasks(context).map(\.id)))
        if !taskIDs.isEmpty {
            let rows = try fetchRows(FetchDescriptor<TaskItem>(predicate: #Predicate { taskIDs.contains($0.id) }), in: context)
            for task in TaskStore.canonicalReplicas(from: rows) where task.deletedAt == nil {
                record(AtticItemRef(.task, task.id), Self.item(task.tagsRaw, task.createdAt))
            }
        }
        let noteIDs = Array(Set(try fetchRows(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.tagsRaw != "" }), in: context, counted: false).map(\.id)))
        if !noteIDs.isEmpty {
            let rows = try fetchRows(FetchDescriptor<NoteItem>(predicate: #Predicate { noteIDs.contains($0.id) }), in: context)
            for note in NoteStore.canonicalReplicas(from: rows) where note.deletedAt == nil {
                record(AtticItemRef(.note, note.id), Self.item(note.tagsRaw, note.createdAt))
            }
        }
        if !AtticLegacyCanvas.isDormant(context) {
            let boardIDs = Array(Set(try fetchRows(FetchDescriptor<CanvasBoardItem>(predicate: #Predicate { $0.tagsRaw != "" }), in: context, counted: false).map(\.id)))
            if !boardIDs.isEmpty {
                let rows = try fetchRows(FetchDescriptor<CanvasBoardItem>(predicate: #Predicate { boardIDs.contains($0.id) }), in: context)
                for replicas in Dictionary(grouping: rows, by: \.id).values {
                    record(AtticItemRef(.canvas, replicas[0].id), Self.boardItem(replicas))
                }
            }
        }
        return (result, firstUse)
    }

    private func save(_ context: ModelContext) -> Bool {
        invalidate(in: context)
        do {
            try WorkspaceLegacyBridge.persist(context, using: persist, sourceName: "TagService")
            lastErrorMessage = nil
        } catch {
            context.rollback()
            // The outcome of a failed write may still be unknown (a held
            // commit): the model builds again from what the store holds.
            invalidateInventory()
            lastErrorMessage = error.localizedDescription
            return false
        }
        // The stores reload first (their reloads reconcile the kinds they
        // read, after the Done index has the saved rows); what is left is
        // patched and published after them, so no publication runs ahead of
        // the Done index.
        afterChange()
        publishInventoryChange()
        return true
    }
}
