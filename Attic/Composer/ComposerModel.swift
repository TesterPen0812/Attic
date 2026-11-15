import AppKit
import Darwin
import Foundation
import SwiftData
import SwiftUI

/// What the "+" card makes (Accepted 2026-10-29, "The '+' card").
enum ComposerKind: String, CaseIterable, Equatable, Sendable {
    case task, event, note

    var title: String {
        switch self {
        case .task: String(localized: "Task")
        case .event: String(localized: "Event")
        case .note: String(localized: "Note")
        }
    }

    var placeholder: String {
        switch self {
        case .task: String(localized: "New task")
        case .event: String(localized: "New event")
        case .note: String(localized: "New note")
        }
    }
}

/// The page the card opens on: it decides the kinds on offer, the kind "+"
/// opens on, where a task goes and which history a creation joins.
enum ComposerPage: Equatable {
    case tasks(TasksTab)
    case calendar(selected: DueDay)
    case notes

    /// The Tasks tab the card opened on, if it opened on Tasks.
    var tasksTab: TasksTab? {
        if case let .tasks(tab) = self { tab } else { nil }
    }

    /// Events only on the Calendar page (Accepted 2026-10-30): Task · Note
    /// on Tasks, Task · Event · Note on Calendar.
    var kinds: [ComposerKind] {
        switch self {
        case .tasks: [.task, .note]
        case .calendar: [.task, .event, .note]
        case .notes: [.note]
        }
    }

    var ownKind: ComposerKind {
        switch self {
        case .tasks: .task
        case .calendar: .event
        case .notes: .note
        }
    }

    /// Each creation is one Undo step in the history ⌘Z reaches on the page
    /// it was made on (events: the writer's own `.calendar` steps).
    var history: UndoHistoryID {
        switch self {
        case .tasks: .tasks
        case .calendar: .calendar
        case .notes: .notesLibrary
        }
    }
}

/// What the card asks of the panel. Every event write goes through
/// `makeWriter`; tests inject a fake-backed writer, never a live store.
struct ComposerServices {
    var makeWriter: (() throws -> CalendarEventWriter)?
    var openTaskPage: (UUID) -> Void = { _ in }
    var openNote: (UUID) -> Void = { _ in }
    var openEvent: (CalendarOwnedEvent) -> Void = { _ in }
    /// A creation's notice and its Undo.
    var toast: (String, @escaping @MainActor () -> CommandOutcome) -> Void = { _, _ in }
    /// A failed Calendar write whose card was dismissed or replaced.
    var eventFailure: (String) -> Void = { _ in }
    /// Where a kept draft waits across a quit (A2); nil keeps it in memory only.
    var drafts: ComposerDraftStore? = nil
    var taskRecoveryIDs: (([UUID]) throws -> Set<UUID>)? = nil
}

/// A draft kept with Escape or a click outside, saved so it comes back
/// after the app quits and relaunches (UX audit A2). The journal keeps the
/// exact draft, its semantic tokens and picks, and its owned staged files.
/// Caret, selection and typing Undo stay in memory.
@MainActor
struct ComposerDraftStore {
    struct Draft: Codable, Equatable {
        var title: String
        var writing: String
        var kind: String
        var recoveringTaskID: UUID? = nil
        var textState: TaskAddBarText? = nil
        var isPinned: Bool? = nil
        var seededTags: [String]? = nil
        var dateAnchor: Date? = nil
        var dateTimeZone: String? = nil
        var dateLocaleID: String? = nil
        var files: [FileBatch]? = nil
        var pendingFiles: Bool? = nil
        var eventLength: Int? = nil
        var calendarID: String? = nil

        var addBar: TaskAddBarText { textState ?? TaskAddBarText(text: title) }
        var isEmpty: Bool {
            addBar == TaskAddBarText() && writing.isEmpty && isPinned != true && (files ?? []).isEmpty
        }
    }

    struct FileBatch: Codable, Equatable, Sendable {
        var id: UUID
        var urls: [URL]
    }

    /// The shown owner and the other owner's words travel together. An empty
    /// shown draft still records which kind the person left open.
    struct KeptDrafts: Codable, Equatable {
        var shown: Draft
        var aside: Draft?
    }

    /// Failed submissions wait separately from the current card's kept draft,
    /// so a later task or note cannot overwrite an event that never saved.
    struct FailedEvent: Codable, Equatable {
        var title: String
        var writing: String
        var day: DueDay?
        var length: Int
        var calendarID: String?
    }

    /// A failed task must outlive a newer draft and a panel relaunch. The
    /// queued words and picked values are separate from the active card.
    struct FailedTask: Codable, Equatable {
        enum Origin: Codable, Equatable {
            case tasks(Int)
            case calendar(DueDay)
        }

        var id: UUID
        var title: String
        var writing: String
        var pickedDay: DueDay?
        var pickedPriority: TaskPriority?
        var pickedTags: [String]
        var status: TaskStatus
        var origin: Origin
        var draftState: Draft? = nil
        var committed: Bool? = nil

        init(id: UUID, title: TaskAddBarText, writing: String, status: TaskStatus, page: ComposerPage) {
            self.id = id
            self.title = title.text
            self.writing = writing
            pickedDay = title.picked.day
            pickedPriority = title.picked.priority
            pickedTags = title.picked.tags
            self.status = status
            switch page {
            case let .tasks(tab): origin = .tasks(tab.rawValue)
            case let .calendar(day): origin = .calendar(day)
            case .notes: origin = .tasks(TasksTab.now.rawValue)
            }
        }

        var page: ComposerPage {
            switch origin {
            case let .tasks(raw): .tasks(TasksTab(rawValue: raw) ?? .now)
            case let .calendar(day): .calendar(selected: day)
            }
        }

        var addBar: TaskAddBarText {
            if let state = draftState { return state.addBar }
            var result = TaskAddBarText(text: title)
            result.picked.day = pickedDay
            result.picked.priority = pickedPriority
            result.picked.tags = pickedTags
            return result
        }
    }

    let defaults: UserDefaults
    var key = "composerKeptDraft"
    var failedEventsKey: String? = nil
    /// Production supplies a sidecar next to its local store. Tests must
    /// explicitly supply a temporary URL; nil retains the legacy test seam.
    var taskRecoveryURL: URL? = nil
    var persistTaskRecovery: (Data, URL) throws -> Void = ComposerDraftStore.writeTaskRecovery
    var readTaskRecovery: (URL) throws -> Data = { try Data(contentsOf: $0) }

    // Docked keeps its legacy key; floating pages own independent drafts.
    static func forPanel(defaults: UserDefaults, floatingPage: PanelPage?) -> Self {
        Self(defaults: defaults,
            key: floatingPage.map { "composerKeptDraft.floating.\($0.rawValue)" } ?? "composerKeptDraft",
            failedEventsKey: "composerKeptDraft.failedEvents")
    }

    private static func writeTaskRecovery(_ data: Data, _ url: URL) throws {
        // The store directory already exists. Atomic replacement plus both
        // fsyncs acknowledges process-crash durability before clearing text.
        try data.write(to: url, options: .atomic)
        for target in [url, url.deletingLastPathComponent()] {
            let fd = open(target.path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            guard fsync(fd) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        }
    }

    /// One atomic document owns both the kept card and pending submissions.
    /// Consuming a kept draft and adding its pending record cannot tear apart
    /// across a crash, even when UserDefaults still contains an older copy.
    struct TaskRecovery: Codable, Equatable {
        var tasks: [FailedTask]
        var draft: Draft?
        var aside: Draft? = nil
        var panels: [String: KeptDrafts]? = nil
        var retired: [UUID]? = nil
        var migratedPanels: [String]? = nil

        var fileBatches: [FileBatch] {
            tasks.flatMap { $0.draftState?.files ?? [] } + panelKeys.flatMap { key in
                guard let kept = panel(key) else { return [FileBatch]() }
                return (kept.shown.files ?? []) + (kept.aside?.files ?? [])
            }
        }
        var panelKeys: [String] { ["composerKeptDraft"] + Array((panels ?? [:]).keys) }
        func panel(_ key: String) -> KeptDrafts? {
            if key == "composerKeptDraft" { return draft.map { KeptDrafts(shown: $0, aside: aside) } }
            return panels?[key]
        }
        mutating func setPanel(_ kept: KeptDrafts?, key: String) {
            if key == "composerKeptDraft" { draft = kept?.shown; aside = kept?.aside }
            else { if panels == nil { panels = [:] }; panels?[key] = kept }
        }
        mutating func clearKeptRecoveries(_ ids: Set<UUID>) {
            for key in panelKeys {
                guard var kept = panel(key) else { continue }
                if let id = kept.shown.recoveringTaskID, ids.contains(id) {
                    kept.shown = Draft(title: "", writing: "", kind: kept.shown.kind)
                }
                if let id = kept.aside?.recoveringTaskID, ids.contains(id) { kept.aside = nil }
                setPanel(kept.shown.isEmpty && kept.aside == nil ? nil : kept, key: key)
            }
        }
    }

    func loadLegacyKeptDrafts() -> KeptDrafts? {
        guard let data = defaults.data(forKey: key) else { return nil }
        if let kept = try? JSONDecoder().decode(KeptDrafts.self, from: data) { return kept }
        // The former single-entry format remains readable without changing
        // its words or kind. The next save writes the owned format.
        return (try? JSONDecoder().decode(Draft.self, from: data)).map { KeptDrafts(shown: $0) }
    }

    func loadKeptDrafts() -> KeptDrafts? { try? readRecovery().panel(key) }

    @discardableResult
    func saveKeptDrafts(_ kept: KeptDrafts) -> Bool {
        ComposerRecoveryJournal.shared(self).change(self) { journal in
            journal.setPanel(kept.shown.isEmpty && kept.aside == nil ? nil : kept, key: key)
        }
    }

    private func loadLegacyDraft() -> Draft? { loadLegacyKeptDrafts()?.shown }

    func load() -> Draft? {
        guard let kept = loadKeptDrafts() else { return nil }
        return kept.shown.isEmpty ? kept.aside : kept.shown
    }

    @discardableResult
    func save(_ input: Draft?) -> Bool {
        ComposerRecoveryJournal.shared(self).change(self) { journal in
            journal.setPanel(input.flatMap { $0.isEmpty ? nil : KeptDrafts(shown: $0) }, key: key)
        }
    }

    func loadFailedEvents() -> [FailedEvent] {
        guard let data = defaults.data(forKey: failedEventsKey ?? key + ".failedEvents") else { return [] }
        return (try? JSONDecoder().decode([FailedEvent].self, from: data)) ?? []
    }

    func saveFailedEvents(_ events: [FailedEvent]) {
        let storageKey = failedEventsKey ?? key + ".failedEvents"
        guard !events.isEmpty else { defaults.removeObject(forKey: storageKey); return }
        guard let data = try? JSONEncoder().encode(events) else { return }
        defaults.set(data, forKey: storageKey)
    }

    func loadFailedTasks() -> [FailedTask] {
        (try? readFailedTasks()) ?? []
    }

    func readFailedTasks() throws -> [FailedTask] { try readRecovery().tasks }

    private func legacyKeptDrafts(tasks: [FailedTask]) -> TaskRecovery {
        var result = TaskRecovery(tasks: tasks, draft: nil)
        let keys = ["composerKeptDraft", key] + PanelPage.allCases.map { "composerKeptDraft.floating.\($0.rawValue)" }
        for panelKey in Set(keys) {
            var legacy = self
            legacy.key = panelKey
            if let kept = legacy.loadLegacyKeptDrafts() { result.setPanel(kept, key: panelKey) }
        }
        return result
    }

    private func authoritative(_ input: TaskRecovery) -> TaskRecovery {
        var result = input
        // An existing full journal owns the docked slot even when empty.
        // A stale defaults backup must not undo atomic consumption/retirement.
        if !(result.migratedPanels ?? []).contains("composerKeptDraft") {
            result.migratedPanels = (result.migratedPanels ?? []) + ["composerKeptDraft"]
        }
        return result
    }

    func readRecovery() throws -> TaskRecovery {
        if let taskRecoveryURL, FileManager.default.fileExists(atPath: taskRecoveryURL.path) {
            let bytes = try readTaskRecovery(taskRecoveryURL)
            if let recovery = try? JSONDecoder().decode(TaskRecovery.self, from: bytes) { return authoritative(recovery) }
            // Earlier pending-only JSON did not own the kept-draft defaults.
            return legacyKeptDrafts(tasks: try JSONDecoder().decode([FailedTask].self, from: bytes))
        }
        if let data = defaults.data(forKey: "composerRecoveryJournal"),
           let journal = try? JSONDecoder().decode(TaskRecovery.self, from: data) { return authoritative(journal) }
        var tasks: [FailedTask] = []
        var seen: Set<UUID> = []
        for storageKey in ["composerKeptDraft.failedTasks", key + ".failedTasks"] {
            guard let data = defaults.data(forKey: storageKey) else { continue }
            for task in try JSONDecoder().decode([FailedTask].self, from: data) where seen.insert(task.id).inserted {
                tasks.append(task)
            }
        }
        return legacyKeptDrafts(tasks: tasks)
    }

    func persistRecovery(_ recovery: TaskRecovery) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(recovery)
        if let taskRecoveryURL { try persistTaskRecovery(data, taskRecoveryURL) }
        else { defaults.set(data, forKey: "composerRecoveryJournal") }
        for panelKey in Set(recovery.panelKeys + (recovery.migratedPanels ?? [])) {
            defaults.removeObject(forKey: panelKey)
            defaults.removeObject(forKey: panelKey + ".failedTasks")
        }
    }

    #if DEBUG
    /// Legacy import/test adapter. Live models only use journal upsert/retire.
    @discardableResult
    func saveFailedTasks(_ tasks: [FailedTask], consumingKeptDraft: Bool = false) -> Bool {
        ComposerRecoveryJournal.shared(self).change(self) { journal in
            journal.tasks = tasks
            if consumingKeptDraft { journal.setPanel(nil, key: key) }
        }
    }

    #endif

    var ownedFilesURL: URL? {
        taskRecoveryURL.map { URL(fileURLWithPath: $0.path.replacingOccurrences(of: ".composer-tasks.json", with: ".composer-files") + ($0.path.hasSuffix(".composer-tasks.json") ? "" : ".files"), isDirectory: true) }
    }

    /// Copy before publishing the reference; a picker URL may not be readable
    /// in the next sandbox session, and temporary drop staging may be swept.
    func keepFiles(_ files: [TasksComposerFiles]) throws -> [FileBatch] {
        guard let root = ownedFilesURL else { return [] }
        return try Self.copyFileBatches(files, root: root)
    }
    nonisolated static func copyFileBatches(_ files: [TasksComposerFiles], root: URL) throws -> [FileBatch] {
        return try files.map { batch in
            let directory = root.appendingPathComponent(batch.id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var copied = false
            let urls = try batch.staging.urls.enumerated().map { index, source -> URL in
                let destination = directory.appendingPathComponent("\(index)").appendingPathComponent(source.lastPathComponent)
                if source.standardizedFileURL != destination.standardizedFileURL,
                   !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let access = source.startAccessingSecurityScopedResource()
                    defer { if access { source.stopAccessingSecurityScopedResource() } }
                    let temporary = destination.deletingLastPathComponent().appendingPathComponent(".copy-\(UUID().uuidString)")
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    let input = source.resolvingSymlinksInPath()
                    guard try input.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                        throw CocoaError(.fileReadUnsupportedScheme)
                    }
                    try FileManager.default.copyItem(at: input, to: temporary)
                    try Self.sync(temporary)
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    copied = true
                    try Self.sync(destination.deletingLastPathComponent())
                }
                guard FileManager.default.isReadableFile(atPath: destination.path) else { throw CocoaError(.fileReadNoSuchFile) }
                return destination
            }
            if copied { try Self.sync(directory); try Self.sync(root) }
            return FileBatch(id: batch.id, urls: urls)
        }
    }
    nonisolated private static func sync(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
    func restoreFiles(_ batches: [FileBatch]) -> (files: [TasksComposerFiles], missing: Bool) {
        guard let root = ownedFilesURL?.standardizedFileURL.resolvingSymlinksInPath() else { return ([], !batches.isEmpty) }
        var missing = false
        let files = batches.compactMap { batch -> TasksComposerFiles? in
            let valid = batch.urls.filter { url in
                let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
                let exists = resolved.path.hasPrefix(root.path + "/") && FileManager.default.isReadableFile(atPath: resolved.path)
                if !exists { missing = true }
                return exists
            }
            return valid.isEmpty ? nil : TasksComposerFiles(id: batch.id, staging: TaskAttachmentStaging(urls: valid))
        }
        return (files, missing)
    }

    func cleanFiles(_ previous: [FileBatch], keeping current: [FileBatch]) {
        guard let root = ownedFilesURL?.standardizedFileURL.resolvingSymlinksInPath() else { return }
        let retained = Set(current.map(\.id))
        for batch in previous where !retained.contains(batch.id) {
            let directory = root.appendingPathComponent(batch.id.uuidString)
            guard directory.deletingLastPathComponent() == root else { continue }
            do { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
            catch { NSLog("Composer staged-file cleanup failed: %@", error.localizedDescription) }
        }
    }

}

/// One process owner per store. Panels change records, never a cached list.
/// The local store's writer lease excludes a second app process.
@MainActor
final class ComposerRecoveryJournal {
    typealias Store = ComposerDraftStore
    private static var owners: [String: ComposerRecoveryJournal] = [:]
    static func shared(_ store: Store?) -> ComposerRecoveryJournal {
        guard let store else { return ComposerRecoveryJournal(nil) }
        let identity = store.taskRecoveryURL?.standardizedFileURL.resolvingSymlinksInPath().path
            ?? "defaults:\(ObjectIdentifier(store.defaults))"
        if let owner = owners[identity] { owner.adoptPanel(store); return owner }
        let owner = ComposerRecoveryJournal(store)
        owners[identity] = owner
        return owner
    }
    /// A permanent purge must not remove the last physical proof of a
    /// committed UUID while its recovery retirement is still unwritten.
    private let containers = NSHashTable<ModelContainer>.weakObjects()
    func bind(_ container: ModelContainer) { containers.add(container) }

    static func prepareToPurge(_ ids: Set<UUID>, in container: ModelContainer) -> Bool {
        var relevant = owners.values.filter { owner in owner.containers.allObjects.contains { $0 === container } }
        if relevant.isEmpty, let configuration = container.configurations.first, !configuration.isStoredInMemoryOnly {
            let url = configuration.url.appendingPathExtension("composer-tasks.json")
            if FileManager.default.fileExists(atPath: url.path) {
                relevant = [shared(Store(defaults: .standard, taskRecoveryURL: url))]
            }
        }
        for owner in relevant {
            guard owner.ready(owner.lastStore) else { return false }
            let matching = Set(owner.tasks.map(\.id)).intersection(ids)
            guard owner.retire(matching, store: owner.lastStore) else { return false }
        }
        return true
    }

    #if DEBUG
    /// Test-process relaunch: forget live leases and reload the actual bytes.
    /// Old held callbacks may still be driven to exercise commit/crash windows.
    static func simulateProcessExitForTesting(_ store: Store? = nil) {
        let selected = store.map { [shared($0)] } ?? Array(owners.values)
        for owner in selected {
            owner.leases.removeAll(); owner.panels.removeAll(); owner.saving.removeAll()
            owner.loaded = false; owner.durable = nil
            owner.document = Store.TaskRecovery(tasks: [], draft: nil)
            _ = owner.ready(store ?? owner.lastStore)
        }
    }
    #endif
    private final class Lease { weak var model: ComposerModel?; init(_ model: ComposerModel) { self.model = model } }
    private var leases: [UUID: Lease] = [:]
    private var panels: [String: Lease] = [:]
    func registerPanel(_ key: String, model: ComposerModel) { panels[key] = Lease(model) }
    func ownsPanel(_ key: String, model: ComposerModel) -> Bool {
        panels[key]?.model == nil || panels[key]?.model === model
    }
    private var saving: Set<UUID> = []
    func beginSaving(_ id: UUID) { saving.insert(id) }
    func endSaving(_ id: UUID) { saving.remove(id) }
    private(set) var document = Store.TaskRecovery(tasks: [], draft: nil)
    private var durable: Store.TaskRecovery?
    private var loaded = false
    private var lastStore: Store?
    private(set) var notice: String?
    var tasks: [Store.FailedTask] { document.tasks }
    private var retiredIDs: Set<UUID> = []
    var retired: Set<UUID> { retiredIDs }
    func takeNotice() -> String? { defer { notice = nil }; return notice }

    init(_ store: Store?) { _ = ready(store) }
    @discardableResult
    func ready(_ store: Store?) -> Bool {
        if let store { lastStore = store }
        if loaded {
            if let store { adoptPanel(store) }
            return true
        }
        guard let store else { loaded = true; durable = document; return true }
        do {
            document = try store.readRecovery()
            retiredIDs = Set(document.retired ?? [])
            durable = document; loaded = true
            adoptPanel(store)
            // Adoption markers ride the next real checkpoint; constructing
            // an empty add bar need not create or fsync a journal.
            durable = document
            return true
        } catch is DecodingError {
            guard let url = store.taskRecoveryURL else {
                notice = "Couldn’t read drafts. Try again."
                return false
            }
            do {
                let backup = url.appendingPathExtension("damaged-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: url, to: backup)
                notice = "Draft recovery damaged. Original kept."
                document = Store.TaskRecovery(tasks: [], draft: nil)
                loaded = true; durable = nil
                return true
            } catch {
                notice = "Couldn’t read drafts. Try again."
                return false
            }
        } catch {
            // If the bytes cannot be read but the directory can be written,
            // keep the original beside the store and let new drafts proceed.
            if let url = store.taskRecoveryURL, FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("unreadable-\(UUID().uuidString)"))
                    notice = "Draft unreadable. Original kept."
                    document = Store.TaskRecovery(tasks: [], draft: nil)
                    loaded = true; durable = nil
                    return true
                } catch { }
            }
            notice = "Couldn’t read drafts. Try again."
            return false
        }
    }
    private func adoptPanel(_ store: Store) {
        guard loaded, !(document.migratedPanels ?? []).contains(store.key) else { return }
        let wasClean = durable == document
        if document.panel(store.key) == nil, let kept = store.loadLegacyKeptDrafts() {
            document.setPanel(kept, key: store.key)
        }
        document.migratedPanels = (document.migratedPanels ?? []) + [store.key]
        if wasClean { durable = document }
    }
    func kept(_ key: String) -> Store.KeptDrafts? { document.panel(key) }
    func available(_ id: UUID, to model: ComposerModel) -> Bool {
        !retired.contains(id) && (leases[id]?.model == nil || leases[id]?.model === model)
    }
    func isSaving(_ id: UUID) -> Bool { saving.contains(id) }
    func claim(_ id: UUID, by model: ComposerModel) -> Bool {
        guard available(id, to: model) else { return false }
        leases[id] = Lease(model); return true
    }
    func release(_ id: UUID, by model: ComposerModel) {
        if leases[id]?.model === model { leases[id] = nil }
    }
    @discardableResult
    func change(_ store: Store?, _ edit: (inout Store.TaskRecovery) -> Void) -> Bool {
        guard ready(store) else { return false }
        edit(&document)
        return flush(store)
    }
    @discardableResult
    func flush(_ store: Store?) -> Bool {
        guard ready(store) else { return false }
        guard document != durable else { return true }
        guard let store else { durable = document; return true }
        do {
            let previousFiles = durable?.fileBatches ?? []
            try store.persistRecovery(document)
            durable = document
            store.cleanFiles(previousFiles, keeping: document.fileBatches)
            return true
        } catch {
            notice = "Couldn’t save draft. Try again."
            return false
        }
    }
    @discardableResult
    func upsert(_ task: Store.FailedTask, consumingPanel key: String?, store: Store?, keepingAside: Store.Draft? = nil) -> Bool {
        change(store) { journal in
            if let index = journal.tasks.firstIndex(where: { $0.id == task.id }) { journal.tasks[index] = task }
            else { journal.tasks.append(task) }
            if task.committed == true { journal.clearKeptRecoveries([task.id]) }
            if let key {
                let shown = Store.Draft(title: "", writing: "", kind: journal.panel(key)?.shown.kind ?? "task")
                journal.setPanel(keepingAside.map { Store.KeptDrafts(shown: shown, aside: $0) }, key: key)
            }
        }
    }
    @discardableResult
    func retire(_ ids: Set<UUID>, store: Store?, keepingPanel: String? = nil, kept: Store.KeptDrafts? = nil) -> Bool {
        guard !ids.isEmpty else { return flush(store) }
        retiredIDs.formUnion(ids)
        return change(store) { journal in
            journal.tasks.removeAll { ids.contains($0.id) }
            journal.retired = nil
            journal.clearKeptRecoveries(ids)
            if let key = keepingPanel { journal.setPanel(kept, key: key) }
        }
    }
}

/// The "+" card's state. It lives as long as the panel, so a draft dismissed
/// with Escape or a click outside is there again on the next "+", on any page.
/// The title is the add bar's draft (`TasksPageModel.addBarState`): its
/// shorthand, picks, suggestions and typing Undo carry over unchanged.
@MainActor
final class ComposerModel: ObservableObject {
    let tasks: TasksPageModel
    var services: ComposerServices {
        didSet {
            if services.drafts?.taskRecoveryURL != oldValue.drafts?.taskRecoveryURL
                || (services.drafts == nil) != (oldValue.drafts == nil) {
                recoveryOwner = ComposerRecoveryJournal.shared(services.drafts)
                recoveryOwner.bind(tasks.store.container)
                recoveryOwner.registerPanel(services.drafts?.key ?? "composerKeptDraft", model: self)
                configureFilePersistence()
            }
        }
    }

    @Published private(set) var isOpen = false
    /// Bumped by every open, even on an open card: the keyboard goes back
    /// to the title (the hotkey pressed again after a click elsewhere).
    @Published private(set) var focusRequest = 0
    @Published private(set) var page: ComposerPage = .tasks(.now)
    @Published private(set) var kind: ComposerKind = .task
    /// The second line: the task's, event's or note's writing.
    @Published var writing = ""
    @Published var pinned = false
    /// An event's length in minutes, for a timed event.
    @Published var eventLength = 60
    @Published var calendarID: String?
    @Published private(set) var calendars: [CalendarWriteCalendar] = []
    /// A creation that did not save: the draft stays, the card says so.
    @Published private(set) var failed = false
    @Published private(set) var isCreating = false

    /// The card's title field.
    let editor = AtticTokenFieldEditor()
    private var writer: CalendarEventWriter?
    private var calendarLoad: Task<[CalendarWriteCalendar], Never>?
    private var calendarLoadGeneration = 0
    private var draftGeneration = 0
    private var failedEventDrafts: [ComposerDraftStore.FailedEvent] = []
    private var recoveringFailedEvent: ComposerDraftStore.FailedEvent?
    private var seededTags: [String]?
    private var openingTags: [String]?
    private var openingCard = false
    private var recoveryOwner: ComposerRecoveryJournal
    private var failedTaskDrafts: [ComposerDraftStore.FailedTask] { recoveryOwner.tasks }
    private static let live = NSHashTable<ComposerModel>.weakObjects()

    static func prepareForTermination(in container: ModelContainer) -> Bool {
        var ready = true
        for model in live.allObjects where model.tasks.store.container === container {
            if model.tasks.addBarState.stagingFiles > 0 {
                model.recoveryNotice("Files preparing. Wait before quitting.")
                ready = false
            }
            if !model.saveKeptDraft() { ready = false }
        }
        return ready
    }
    private var failedTaskContents: [UUID: (title: TaskAddBarText, files: [TasksComposerFiles])] = [:]
    private var recoveringFailedTaskID: UUID?


    static let lengths = [30, 60, 90, 120]

    init(tasks: TasksPageModel, services: ComposerServices = ComposerServices()) {
        self.tasks = tasks
        self.services = services
        recoveryOwner = ComposerRecoveryJournal.shared(services.drafts)
        Self.live.add(self)
        recoveryOwner.bind(tasks.store.container)
        recoveryOwner.registerPanel(services.drafts?.key ?? "composerKeptDraft", model: self)
        configureFilePersistence()
        failedEventDrafts = services.drafts?.loadFailedEvents() ?? []
        _ = reconcileTaskRecovery()
        restoreKeptDraft()
        _ = restoreFailedTaskIfAvailable(restoringKeptDraft: true)
    }

    // MARK: The kept draft (A2)

    /// A draft saved before a quit comes back into an empty card.
    private func configureFilePersistence() {
        title.checkpointComposerFiles = { [weak self] in _ = self?.saveKeptDraft() }
        guard let root = services.drafts?.ownedFilesURL else {
            title.prepareComposerFiles = nil
            title.discardPreparedComposerFiles = nil
            return
        }
        title.prepareComposerFiles = { batch in
            let saved = try await Task.detached {
                try ComposerDraftStore.copyFileBatches([batch], root: root)
            }.value
            var prepared = batch
            prepared.staging.urls = saved.flatMap(\.urls)
            return prepared
        }
        title.discardPreparedComposerFiles = { batch in
            // A late provider belongs to an explicitly discarded generation;
            // it was never published in any journal record.
            let directory = root.appendingPathComponent(batch.id.uuidString)
            Task.detached { try? FileManager.default.removeItem(at: directory) }
        }
    }

    private func recoveryNotice(_ message: String? = nil) {
        if let message = message ?? recoveryOwner.takeNotice() { tasks.toasts.showFailure(message) }
    }

    @discardableResult
    private func reconcileTaskRecovery() -> Bool {
        guard recoveryOwner.ready(services.drafts) else { recoveryNotice(); return false }
        let keptIDs = recoveryOwner.document.panelKeys.flatMap { key -> [UUID] in
            guard let kept = recoveryOwner.kept(key) else { return [] }
            return [kept.shown.recoveringTaskID, kept.aside?.recoveringTaskID].compactMap { $0 }
        }
        let ids = Array(Set(failedTaskDrafts.map(\.id) + keptIDs)).filter { !recoveryOwner.isSaving($0) }
        do {
            let committed: Set<UUID>
            var physical: [TaskItem] = []
            if let fetch = services.taskRecoveryIDs { committed = try fetch(ids) }
            else if ids.isEmpty { committed = [] }
            else {
                physical = try ModelContext(tasks.store.container).fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { ids.contains($0.id) }))
                committed = Set(physical.map(\.id))
            }
            var retiring = committed.union(failedTaskDrafts.filter { $0.committed == true && ids.contains($0.id) }.map(\.id))
                .union(recoveryOwner.retired.intersection(ids))
            for record in failedTaskDrafts where committed.contains(record.id) {
                if resumeCommittedFiles(record, rows: physical.filter { $0.id == record.id }) { retiring.remove(record.id) }
            }
            guard recoveryOwner.retire(retiring, store: services.drafts) else { recoveryNotice(); return false }
            recoveryNotice() // including a quarantined original
            return true
        } catch {
            recoveryNotice("Couldn’t check drafts. Try again.")
            return false
        }
    }

    /// A committed row can precede its file import at a crash. Resume only
    /// missing content; references removed by the person count as consumed.
    private func resumeCommittedFiles(_ record: ComposerDraftStore.FailedTask, rows: [TaskItem]) -> Bool {
        guard let state = record.draftState, let batches = state.files, !batches.isEmpty,
              let store = services.drafts else { return false }
        guard rows.contains(where: { $0.deletedAt == nil }) else { return false }
        guard recoveryOwner.claim(record.id, by: self) else { return true }
        recoveryOwner.beginSaving(record.id)
        var committed = record
        committed.committed = true
        if !recoveryOwner.upsert(committed, consumingPanel: nil, store: store) { recoveryNotice() }
        let restored = store.restoreFiles(batches)
        if restored.missing {
            recoveryNotice("Re-attach missing files to the task.")
        }
        let existing = rows.flatMap { $0.attachments + $0.removedAttachments.map(\.reference) }
        Task { @MainActor [self] in
            // Compare immutable file digests off the UI actor, including
            // multiplicity (two intentionally attached equal files stay two).
            let urls = restored.files.flatMap { $0.staging.urls }
            let fingerprints = await Task.detached {
                urls.map { url -> String? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return NotePayloadDigest.sha256(data)
                }
            }.value
            var consumed: [String: Int] = [:]
            for reference in Dictionary(grouping: existing, by: \.id).values.compactMap(\.first) {
                let key = reference.filename + ":" + reference.digest.lowercased()
                consumed[key, default: 0] += 1
            }
            var remaining: [URL] = []
            for (url, digest) in zip(urls, fingerprints) {
                guard let digest else {
                    recoveryOwner.endSaving(record.id)
                    recoveryOwner.release(record.id, by: self)
                    recoveryNotice("Re-attach missing files to the task.")
                    return
                }
                let key = url.lastPathComponent + ":" + digest.lowercased()
                if consumed[key, default: 0] > 0 { consumed[key, default: 0] -= 1 }
                else { remaining.append(url) }
            }
            tasks.attachComposerFiles(remaining.isEmpty ? [] : [TasksComposerFiles(staging: TaskAttachmentStaging(urls: remaining))], to: record.id) { [self] attached in
                recoveryOwner.endSaving(record.id)
                if attached { retireFailedTask(record.id) }
                else {
                    recoveryOwner.release(record.id, by: self)
                    recoveryNotice("Task saved. Files kept for retry.")
                }
            }
        }
        return true
    }

    private func apply(_ saved: ComposerDraftStore.Draft) {
        tasks.addBar = saved.addBar
        title.dateAnchor = saved.dateAnchor
        title.dateTimeZone = saved.dateTimeZone
        title.dateLocaleID = saved.dateLocaleID
        title.seededTags = saved.seededTags
        seededTags = saved.seededTags
        writing = saved.writing
        pinned = saved.isPinned ?? false
        eventLength = saved.eventLength ?? eventLength
        calendarID = saved.calendarID ?? calendarID
        recoveringFailedTaskID = saved.recoveringTaskID
        if saved.kind == "task", saved.textState == nil, saved.files == nil {
            recoveryNotice("Older draft. Re-attach any files.")
        }
        if saved.pendingFiles == true { recoveryNotice("Some files need re-attaching.") }
        if let files = saved.files, let store = services.drafts {
            let restored = store.restoreFiles(files)
            tasks.addBarState.files = restored.files
            if restored.missing { recoveryNotice("Some files need re-attaching.") }
        }
    }

    private func restoreKeptDraft() {
        guard let kept = recoveryOwner.kept(services.drafts?.key ?? "composerKeptDraft"),
              tasks.addBar.text.isEmpty, writing.isEmpty else { return }
        if let id = kept.shown.recoveringTaskID, !recoveryOwner.available(id, to: self) {
            apply(.init(title: "", writing: "", kind: kept.shown.kind, textState: TaskAddBarText()))
        } else { apply(kept.shown) }
        if let kind = ComposerKind(rawValue: kept.shown.kind) { self.kind = kind }
        if let saved = kept.aside, let owner = ComposerKind(rawValue: saved.kind),
           saved.recoveringTaskID.map({ recoveryOwner.available($0, to: self) }) != false {
            asideDraft = AsideDraft(owner: owner, text: saved.addBar, writing: saved.writing,
                pinned: saved.isPinned ?? false, history: TaskDraftHistory(), caret: nil, selection: nil,
                seededTags: saved.seededTags, dateAnchor: saved.dateAnchor, recoveringTaskID: saved.recoveringTaskID,
                dateTimeZone: saved.dateTimeZone, dateLocaleID: saved.dateLocaleID)
            if owner == .task, saved.textState == nil, saved.files == nil {
                recoveryNotice("Older draft. Re-attach any files.")
            }
            if saved.pendingFiles == true { recoveryNotice("Some files need re-attaching.") }
            // The Task's files stay in the shared staging strip while Note is shown.
            if owner == .task, let files = saved.files, let store = services.drafts {
                let restored = store.restoreFiles(files)
                tasks.addBarState.files = restored.files
                if restored.missing { recoveryNotice("Some files need re-attaching.") }
            }
        }
    }

    private func dropUnavailableRecoveryViews() {
        if let id = recoveringFailedTaskID,
           !recoveryOwner.available(id, to: self) || !failedTaskDrafts.contains(where: { $0.id == id }) {
            clearDraft()
            tasks.addBarState.files = [] // another live editor/record owns these references
        }
        if let aside = asideDraft, let id = aside.recoveringTaskID,
           !recoveryOwner.available(id, to: self) || !failedTaskDrafts.contains(where: { $0.id == id }) {
            if aside.owner == .task {
                tasks.addBarState.files = []
                asideDraft = AsideDraft(owner: .task, text: TaskAddBarText(), writing: "", pinned: false,
                    history: TaskDraftHistory(), caret: nil, selection: nil, seededTags: nil,
                    dateAnchor: nil, recoveringTaskID: nil)
            } else { asideDraft = nil }
        }
    }

    private func snapshot(text: TaskAddBarText, writing: String, owner: ComposerKind, pinned: Bool,
                          seededTags: [String]?, anchor: Date?, recoveryID: UUID?, files: [TasksComposerFiles],
                          dateTimeZone: String? = nil, dateLocaleID: String? = nil) throws -> ComposerDraftStore.Draft {
        var saved = ComposerDraftStore.Draft(title: text.text, writing: writing, kind: owner.rawValue, recoveringTaskID: recoveryID)
        saved.textState = text
        saved.isPinned = pinned
        saved.seededTags = seededTags
        let readsDates = owner != .note && !TaskDraftBuilder.collapsed(text.text).isEmpty
        saved.dateAnchor = readsDates ? (anchor ?? tasks.services.now()) : nil
        saved.dateTimeZone = readsDates ? (dateTimeZone ?? title.dateTimeZone ?? tasks.services.calendar().timeZone.identifier) : nil
        saved.dateLocaleID = readsDates ? (dateLocaleID ?? title.dateLocaleID ?? tasks.services.locale.identifier) : nil
        saved.files = try services.drafts?.keepFiles(files)
        saved.pendingFiles = owner == .task && title.stagingFiles > 0
        saved.eventLength = eventLength
        saved.calendarID = calendarID
        return saved
    }

    @discardableResult
    private func rememberFailedTask(_ input: ComposerDraftStore.FailedTask,
                                    title: TaskAddBarText, files: [TasksComposerFiles], consumingKeptDraft: Bool = false) -> Bool {
        var draft = input
        if !consumingKeptDraft, !failedTaskDrafts.contains(where: { $0.id == input.id }) { return false }
        do {
            if !consumingKeptDraft, let state = failedTaskDrafts.first(where: { $0.id == input.id })?.draftState {
                draft.draftState = state
            } else { draft.draftState = try snapshot(text: title, writing: input.writing, owner: .task, pinned: pinned,
                seededTags: self.title.seededTags, anchor: self.title.dateAnchor, recoveryID: input.id, files: files) }
        } catch { recoveryNotice("Couldn’t keep files. Try again."); return false }
        guard recoveryOwner.claim(input.id, by: self) else { recoveryNotice("This task is still saving in another panel."); return false }
        let aside: ComposerDraftStore.Draft?
        do {
            aside = try asideDraft.map { state in
                try snapshot(text: state.text, writing: state.writing, owner: state.owner, pinned: state.pinned,
                    seededTags: state.seededTags, anchor: state.dateAnchor, recoveryID: state.recoveringTaskID,
                    files: state.owner == .task ? tasks.addBarState.files : [],
                    dateTimeZone: state.dateTimeZone, dateLocaleID: state.dateLocaleID)
            }
        } catch { recoveryNotice("Couldn’t keep draft files. Try again."); return false }
        let preserved = recoveryOwner.upsert(draft,
            consumingPanel: consumingKeptDraft ? (services.drafts?.key ?? "composerKeptDraft") : nil,
            store: services.drafts, keepingAside: aside)
        failedTaskContents[draft.id] = (title, consumingKeptDraft && !preserved ? [] : files)
        if !preserved { recoveryNotice() }
        return preserved
    }

    private func retireFailedTask(_ id: UUID?) {
        guard let id else { return }
        if !recoveryOwner.retire([id], store: services.drafts) { recoveryNotice() }
        failedTaskContents[id] = nil
        recoveryOwner.release(id, by: self)
    }

    @discardableResult
    private func restoreFailedTaskIfAvailable(restoringKeptDraft: Bool = false) -> Bool {
        guard recoveryOwner.ownsPanel(services.drafts?.key ?? "composerKeptDraft", model: self),
              kind == .task, !isCreating, tasks.addBarState.stagingFiles == 0 else { return false }
        guard reconcileTaskRecovery() else { return false }
        let preferred = recoveringFailedTaskID
        let available = failedTaskDrafts.filter { $0.committed != true && !recoveryOwner.isSaving($0.id) && recoveryOwner.available($0.id, to: self) }
        guard let saved = preferred.flatMap({ id in available.first { $0.id == id } }) ?? available.first else { return false }
        let alreadyRecovering = recoveringFailedTaskID == saved.id
        guard !holdsRecoverySlot || alreadyRecovering,
              tasks.addBarState.files.isEmpty || alreadyRecovering else { return false }
        guard recoveryOwner.claim(saved.id, by: self) else { return false }
        if !alreadyRecovering {
            if let state = saved.draftState { apply(state) }
            else {
                tasks.addBar = saved.addBar; writing = saved.writing
                recoveryNotice("Older draft. Re-attach any files.")
            }
            if let contents = failedTaskContents[saved.id] {
                tasks.addBar = contents.title
                tasks.addBarState.files = contents.files
                failedTaskContents[saved.id] = (contents.title, [])
            }
        }
        recoveringFailedTaskID = saved.id
        failed = true
        saveKeptDraft()
        return true
    }

    @discardableResult
    func saveKeptDraft() -> Bool {
        guard recoveryOwner.ownsPanel(services.drafts?.key ?? "composerKeptDraft", model: self) else {
            return recoveryOwner.flush(services.drafts)
        }
        if kind != .task, recoveringFailedTaskID != nil, !tasks.composerFilesWait {
            guard prepareKindConversion() else { return false }
        }
        if let id = recoveringFailedTaskID, !hasDraft, !tasks.composerFilesWait {
            retireFailedTask(id)
            recoveringFailedTaskID = nil
            failed = false
        }
        do {
            var shown = try snapshot(text: tasks.addBar, writing: writing, owner: kind, pinned: pinned,
                seededTags: title.seededTags, anchor: title.dateAnchor, recoveryID: recoveringFailedTaskID,
                files: asideDraft?.owner == .task ? [] : tasks.addBarState.files)
            var aside = try asideDraft.map { draft in
                try snapshot(text: draft.text, writing: draft.writing, owner: draft.owner, pinned: draft.pinned,
                    seededTags: draft.seededTags, anchor: draft.dateAnchor, recoveryID: draft.recoveringTaskID,
                    files: draft.owner == .task ? tasks.addBarState.files : [],
                    dateTimeZone: draft.dateTimeZone, dateLocaleID: draft.dateLocaleID)
            }
            if let id = shown.recoveringTaskID, !recoveryOwner.available(id, to: self) {
                shown = .init(title: "", writing: "", kind: shown.kind)
            }
            if let id = aside?.recoveringTaskID, !recoveryOwner.available(id, to: self) { aside = nil }
            let kept = ComposerDraftStore.KeptDrafts(shown: shown, aside: aside)
            title.dateAnchor = shown.dateAnchor
            title.dateTimeZone = shown.dateTimeZone
            title.dateLocaleID = shown.dateLocaleID
            if let aside {
                asideDraft?.dateAnchor = aside.dateAnchor
                asideDraft?.dateTimeZone = aside.dateTimeZone
                asideDraft?.dateLocaleID = aside.dateLocaleID
            }
            let success = recoveryOwner.change(services.drafts) {
                let ids = Set([shown.recoveringTaskID, aside?.recoveringTaskID].compactMap { $0 })
                $0.clearKeptRecoveries(ids)
                for state in [shown, aside].compactMap({ $0 }) {
                    if let id = state.recoveringTaskID, let index = $0.tasks.firstIndex(where: { $0.id == id }) {
                        $0.tasks[index].draftState = state
                        $0.tasks[index].title = state.title
                        $0.tasks[index].writing = state.writing
                        $0.tasks[index].pickedDay = state.addBar.picked.day
                        $0.tasks[index].pickedPriority = state.addBar.picked.priority
                        $0.tasks[index].pickedTags = state.addBar.picked.tags
                    }
                }
                $0.setPanel(shown.isEmpty && aside == nil ? nil : kept, key: services.drafts?.key ?? "composerKeptDraft")
            }
            if !success { recoveryNotice() }
            if success, !isOpen, !openingCard, !isCreating, title.stagingFiles == 0, let id = recoveringFailedTaskID {
                recoveryOwner.release(id, by: self)
            }
            return success
        } catch {
            recoveryNotice("Couldn’t keep files. Try again.")
            return false
        }
    }

    var title: TasksAddBarState { tasks.addBarState }
    var kinds: [ComposerKind] { page.kinds }

    var hasDraft: Bool {
        var picks = tasks.addBar.picked
        if picks.tags == title.seededTags { picks.tags = [] }
        return !TaskDraftBuilder.collapsed(tasks.addBar.text).isEmpty
            || picks != TaskAddBarText.Picks()
            || !writing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || pinned
    }

    private var holdsRecoverySlot: Bool {
        hasDraft || tasks.addBar.picked != TaskAddBarText.Picks() || !(title.seededTags ?? []).isEmpty
    }

    // Keep Create reachable while Task files prepare, so submission can
    // explain the wait through the same notice as the detached add bar.
    var canCreate: Bool {
        !isCreating && !TaskDraftBuilder.collapsed(tasks.addBar.text).isEmpty
    }

    // MARK: Opening and closing

    /// An empty draft starts with `tags` (a filtered page's picked tags),
    /// so what is made there stays in view.
    func startTags(_ tags: [String]) {
        openingTags = tags
    }

    private func seedTags(_ tags: [String]) {
        guard !tags.isEmpty, tasks.addBar == TaskAddBarText(), writing.isEmpty else { return }
        tasks.addBar.picked.tags = tags
        title.seededTags = tags
    }

    /// "+" opens on the page's own kind unless a note draft was kept; ⇧⌘N
    /// asks for Note. A kept event draft is a task outside Calendar.
    func open(on page: ComposerPage, as requested: ComposerKind? = nil) {
        openingCard = true
        defer { openingCard = false }
        dropUnavailableRecoveryViews()
        draftGeneration += 1
        // A file drop explicitly asks for Task before staging begins. Preserve
        // a genuine kept Note; a refused Note switch still owns Task's files.
        if requested == .task, kind == .note, asideDraft == nil, !tasks.composerFilesWait {
            let note = draft(owner: .note)
            if !note.isEmpty { asideDraft = note; clearDraft() }
        }
        openedForQuickNote = requested == .note
        let keptNote = kind == .note && hasDraft
        self.page = page
        if let requested, page.kinds.contains(requested) || requested == .note {
            kind = requested
        } else if !keptNote {
            kind = page.ownKind
        }
        if !page.kinds.contains(kind) { kind = kind == .event ? .task : page.ownKind }
        if !page.kinds.contains(kind) { kind = .note }
        settleDraftOwner()
        if let tags = openingTags { seedTags(tags) }
        openingTags = nil
        if kind != .event { recoveringFailedEvent = nil }
        let recovered = restoreFailedEventIfAvailable()
        if kind != .task || recoveringFailedTaskID == nil { fillCalendarDay() }
        let recoveredTask = restoreFailedTaskIfAvailable()
        if kind == .event { requestCalendars() }
        failed = recoveredTask || (kind == .event && (recovered
            || failedEventDrafts.contains(where: { $0.title == tasks.addBar.text && $0.writing == writing })))
        if !failedEventDrafts.isEmpty {
            services.eventFailure(recovered
                ? String(localized: "Couldn’t save event. Your draft is kept here for retry.")
                : String(localized: "An event wasn’t saved. Open Calendar to retry the kept draft."))
        }
        if !isOpen { returnFocus = NSApp.keyWindow?.firstResponder }
        isOpen = true
        focusRequest &+= 1
    }

    /// Escape or a click outside: the card closes and keeps the draft.
    /// The last close was at once (a page switch), not the fold back into
    /// "+".
    private(set) var closedAtOnce = false
    /// An immediate close can also arrive after an outside press already
    /// started folding. The overlay must still interrupt that in-flight fold.
    @Published private(set) var interruptFoldRequest = 0

    /// `atOnce`: gone in the same frame, whole (a page switch: the card
    /// never comes apart over the moving pages, Accepted 2026-11-04, #9).
    func close(atOnce: Bool = false) {
        guard isOpen else {
            if atOnce {
                closedAtOnce = true
                interruptFoldRequest &+= 1
            }
            return
        }
        draftGeneration += 1
        closedAtOnce = atOnce
        isOpen = false
        // A filter's defaults belong to this opening unless there is writing
        // to keep. Explicitly changed picks remain the person's draft.
        if TaskDraftBuilder.collapsed(tasks.addBar.text).isEmpty && writing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if tasks.addBar.picked.tags == title.seededTags { tasks.addBar.picked.tags = [] }
            title.seededTags = nil
        }
        restoreFocus()
        saveKeptDraft()
        if let id = recoveringFailedTaskID, !isCreating, title.stagingFiles == 0 { recoveryOwner.release(id, by: self) }
    }

    /// What had the keyboard before the card opened.
    private weak var returnFocus: NSResponder?

    /// Closing starts: the keyboard leaves the card at once (it stays on
    /// screen only for the shrink), back to where it was if that is still
    /// in the panel.
    private func restoreFocus() {
        guard let field = editor.textView, let window = field.window else { return }
        let holder = window.firstResponder
        let inCard = holder === field || (holder as? NSTextView)?.isFieldEditor == true
        guard inCard else { return }
        if let back = returnFocus as? NSView, back.window === window, back !== field {
            window.makeFirstResponder(back)
        } else {
            window.makeFirstResponder(nil)
        }
    }

    func choose(_ newKind: ComposerKind) {
        dropUnavailableRecoveryViews()
        guard page.kinds.contains(newKind), newKind != kind else { return }
        kind = newKind
        openedForQuickNote = false
        settleDraftOwner()
        draftGeneration += 1
        if newKind != .event { recoveringFailedEvent = nil }
        let recovered = restoreFailedEventIfAvailable()
        if newKind != .task || recoveringFailedTaskID == nil { fillCalendarDay() }
        let recoveredTask = restoreFailedTaskIfAvailable()
        if newKind == .event { requestCalendars() }
        failed = recoveredTask || (newKind == .event && (recovered
            || failedEventDrafts.contains(where: { $0.title == tasks.addBar.text && $0.writing == writing })))
        if !failedEventDrafts.isEmpty {
            services.eventFailure(recovered
                ? String(localized: "Couldn’t save event. Your draft is kept here for retry.")
                : String(localized: "An event wasn’t saved. Open Calendar to retry the kept draft."))
        }
    }

    /// On Calendar a task or an event starts on the selected day, unless the
    /// draft already has one.
    private func fillCalendarDay() {
        guard case let .calendar(day) = page, kind != .note,
              tasks.addBar.parts(parser: tasks.addBarParser).dueDay == nil else { return }
        var text = tasks.addBar
        text.picked.day = day
        tasks.addBar = text
    }

    // MARK: What the title says

    /// The pieces the title reads for this kind: a task reads `!`, `#tag`,
    /// a day and a time; an event a day and a time; a note `#tag`.
    func reads(_ value: ParsedTaskToken.Value) -> Bool {
        switch (kind, value) {
        case (.task, _): true
        case (.event, .dueDay), (.event, .time): true
        case (.note, .tag): true
        default: false
        }
    }

    private var tokens: [ParsedTaskToken] {
        tasks.addBar.activeTokens(parser: tasks.addBarParser).filter { reads($0.value) }
    }

    /// The tinted pieces of the title line.
    var chips: [AtticTokenChip] {
        let text = tasks.addBar
        let ranges = tokens.map { $0.utf16Range(in: text.text) }
        return text.tokenChips(parser: tasks.addBarParser, caret: title.caret).filter { ranges.contains($0.range) }
    }

    /// A suggestion this kind can use: tags for a task or note, days for a
    /// task or event.
    func suggestion(focused: Bool) -> TaskAddBarText.Suggestion? {
        guard focused, let suggestion = tasks.addBar.suggestion(parser: tasks.addBarParser, caret: title.caret, tags: tasks.cachedTags),
              suggestion.range != title.hiddenSuggestion else { return nil }
        switch (kind, suggestion) {
        case (.task, _), (.event, .date), (.note, .tags): return suggestion
        default: return nil
        }
    }

    struct Values: Equatable {
        var title: String
        var day: DueDay?
        var time: Int?
        var priority: TaskPriority?
        var tags: [String]
    }

    /// What Create would make from the title, for this kind.
    var values: Values {
        let text = tasks.addBar
        switch kind {
        case .task:
            let parts = text.parts(parser: tasks.addBarParser)
            return Values(title: parts.title, day: parts.dueDay, time: parts.dueTimeMinutes,
                          priority: parts.priority, tags: parts.tags)
        case .event:
            let parts = text.parts(parser: tasks.addBarParser)
            return Values(title: TaskTextParser.title(text.text, removing: tokens.map(\.range)),
                          day: parts.dueDay, time: parts.dueTimeMinutes, priority: nil, tags: [])
        case .note:
            var tags: [String] = []
            for token in tokens { if case let .tag(tag) = token.value, !tags.contains(tag) { tags.append(tag) } }
            for tag in text.picked.tags where !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                tags.append(tag)
            }
            return Values(title: TaskTextParser.title(text.text, removing: tokens.map(\.range)),
                          day: nil, time: nil, priority: nil, tags: tags)
        }
    }

    var selectedCalendar: CalendarWriteCalendar? {
        calendars.first { $0.id == calendarID } ?? calendars.first
    }

    // MARK: Creating

    /// Return creates and the card stays open (P4); ⌘Return creates and
    /// opens the item's page. A failure keeps the draft and says so.
    @discardableResult
    func create(openingPage: Bool = false) async -> Bool {
        if kind != .event { return createImmediately(openingPage: openingPage) }
        // Closing has started (Escape, a click outside): nothing creates.
        guard isOpen else { return false }
        guard canCreate else { return false }
        guard !filesWaitForATask(), prepareKindConversion() else { return false }
        isCreating = true
        defer { isCreating = false }
        let generation = draftGeneration
        // Resolve a typed date against a picked date exactly as createEvent
        // does. Persisting the earlier pick would retry on the wrong day.
        var normalized = tasks.addBar
        normalized.typedReplacesPicks(parser: tasks.addBarParser, caret: nil)
        let convertedTaskID = recoveringFailedTaskID
        let submitted = ComposerDraftStore.FailedEvent(title: tasks.addBar.text, writing: writing,
            day: normalized.parts(parser: tasks.addBarParser).dueDay, length: eventLength, calendarID: calendarID)
        switch await createEvent(openingPage: openingPage, generation: generation) {
        case .notSubmitted:
            return false
        case .failed:
            failedEventDrafts = services.drafts?.loadFailedEvents() ?? failedEventDrafts
            if !failedEventDrafts.contains(submitted) {
                failedEventDrafts.append(submitted)
                services.drafts?.saveFailedEvents(failedEventDrafts)
            }
            if generation == draftGeneration && isOpen && kind == .event {
                failed = true
                if tasks.addBar.text == submitted.title && writing == submitted.writing,
                   eventLength == submitted.length, calendarID == submitted.calendarID,
                   recoveringFailedEvent == nil {
                    recoveringFailedEvent = submitted
                }
            }
            services.eventFailure(String(localized: "Couldn’t save event. Your draft is kept; open Calendar to retry."))
            return false
        case let .saved(current):
            retireFailedTask(convertedTaskID)
            let recovered = recoveringFailedEvent
            failedEventDrafts = services.drafts?.loadFailedEvents() ?? failedEventDrafts
            failedEventDrafts.removeAll { $0 == submitted || $0 == recovered }
            services.drafts?.saveFailedEvents(failedEventDrafts)
            recoveringFailedEvent = nil
            guard generation == draftGeneration, current else { AtticSounds.play(.created); return true }
            return finishCreation(true, openingPage: openingPage)
        }
    }

    /// What became of an event submission. `saved(current: false)`: it
    /// saved, but the card now holds a newer draft, which stays.
    private enum EventSubmission { case notSubmitted, failed, saved(current: Bool) }

    /// When Calendar is opened with room for a draft, make the oldest failed
    /// event editable again. Even a relaunched card with that event's words
    /// recovers its original date, calendar and length from the saved proof.
    private func restoreFailedEventIfAvailable() -> Bool {
        failedEventDrafts = services.drafts?.loadFailedEvents() ?? failedEventDrafts
        guard kind == .event, case .calendar = page, let saved = failedEventDrafts.first,
              !hasDraft || (tasks.addBar.text == saved.title && writing == saved.writing) else { return false }
        var text = TaskAddBarText(text: saved.title)
        text.picked.day = saved.day
        tasks.addBar = text
        writing = saved.writing
        eventLength = saved.length
        calendarID = saved.calendarID
        // Keep the durable backup until a later create actually saves. A
        // user may close this card, or quit, before retrying it.
        recoveringFailedEvent = saved
        return true
    }

    /// Only Calendar needs to suspend. Native Return keeps its existing
    /// immediate task/note behavior and schedules an event's durable save.
    func submit(openingPage: Bool = false) {
        // The panel's shared '+' card handles task Return; TasksAddBar.submit
        // handles only detached Tasks views. Record the actual shared path.
        if kind == .task { IdleLatencyTrace.controlDispatched(.addBar) }
        if kind == .event {
            let generation = draftGeneration
            let input = tasks.addBar, notes = writing, length = eventLength, calendar = calendarID
            Task { [weak self] in
                guard let self, self.draftGeneration == generation, self.kind == .event,
                      self.tasks.addBar == input, self.writing == notes, self.eventLength == length,
                      self.calendarID == calendar || (calendar == nil && self.calendarID == self.calendars.first?.id) else { return }
                _ = await self.create(openingPage: openingPage)
            }
        }
        else if kind == .task { submitTaskAcknowledged(openingPage: openingPage) }
        else { _ = createImmediately(openingPage: openingPage) }
    }

    /// Tasks draw their new row before the library's atomic task+writing
    /// transaction starts. Keep the exact draft until the write succeeds;
    /// a failure removes the row and restores its text to this card.
    private func submitTaskAcknowledged(openingPage: Bool) {
        guard isOpen, canCreate, tasks.composerFilesReadyForSubmission() else { return }
        guard reconcileTaskRecovery() else { failed = true; AtticSounds.play(.failed); return }

        if let id = recoveringFailedTaskID, (recoveryOwner.retired.contains(id) || failedTaskDrafts.first(where: { $0.id == id })?.committed == true) {
            recoveringFailedTaskID = nil
            failed = false
            recoveryNotice("Draft saved elsewhere. Words kept.")
            saveKeptDraft()
            return
        }
        var finished = tasks.addBar
        finished.typedReplacesPicks(parser: tasks.addBarParser, caret: nil)
        let day = finished.parts(parser: tasks.addBarParser).dueDay
        let recovering = recoveringFailedTaskID.flatMap { id in failedTaskDrafts.first { $0.id == id } }
        let submittedPage = recovering?.page ?? page
        // In Progress while Now shows only that (13 Nov), so the task
        // doesn't vanish as you make it.
        let status: TaskStatus
        if let recovering {
            // A failed task retains the status it was submitted with. A
            // changed date can still move a Later task into or out of Later.
            status = submittedPage == .tasks(.backlog)
                ? (day == nil ? .backlog : .todo) : recovering.status
        } else {
            status = submittedPage == .tasks(.backlog) && day == nil ? .backlog
                : submittedPage.tasksTab.map(tasks.newOpenStatus(from:)) ?? .todo
        }
        guard let draft = finished.draft(parser: tasks.addBarParser, status: status) else { return }
        let submittedWriting = writing
        let failedSubmission = ComposerDraftStore.FailedTask(id: recovering?.id ?? UUID(),
            title: finished, writing: submittedWriting, status: status, page: submittedPage)
        // A failed recovery write leaves the editor and its files untouched;
        // no optimistic row or asynchronous store command has been issued.
        guard rememberFailedTask(failedSubmission, title: finished, files: tasks.addBarState.files, consumingKeptDraft: true) else {
            recoveringFailedTaskID = failedTaskDrafts.contains(where: { $0.id == failedSubmission.id }) ? failedSubmission.id : nil
            failed = true
            AtticSounds.play(.failed)
            return
        }
        // A file dropped into the next draft while the first saves belongs
        // to the next draft, even if the first save finishes afterwards.
        let submittedFiles = tasks.takeComposerFiles()
        isCreating = true
        recoveryOwner.beginSaving(failedSubmission.id)
        tasks.createAcknowledged(draft, id: failedSubmission.id, save: { [library = tasks.library] id in
            library.createTask(draft, writing: submittedWriting, in: submittedPage.history, id: id)
        }, settled: { [self] created in
            self.isCreating = false
            guard let created else {
                self.recoveryOwner.endSaving(failedSubmission.id)
                self.failed = true
                AtticSounds.play(.failed)
                self.rememberFailedTask(failedSubmission, title: finished, files: submittedFiles)
                self.isOpen = true
                // Recover as soon as there is no newer draft to displace.
                // Its files must travel with its own words, never with the
                // next task's attachment strip.
                let recovered = self.restoreFailedTaskIfAvailable()
                if !recovered {
                    self.recoveryOwner.release(failedSubmission.id, by: self)
                    self.saveKeptDraft()
                }
                self.isOpen = true
                if recovered { self.focusRequest &+= 1 }
                return
            }
            self.failed = false
            if !submittedFiles.isEmpty, var committed = self.failedTaskDrafts.first(where: { $0.id == failedSubmission.id }) {
                committed.committed = true
                if !self.recoveryOwner.upsert(committed, consumingPanel: nil, store: self.services.drafts) { self.recoveryNotice() }
            }
            if submittedFiles.isEmpty {
                self.recoveryOwner.endSaving(failedSubmission.id)
                self.retireFailedTask(failedSubmission.id)
            }
            // Only retire a kept draft after the task's family write commits.
            // Until then an earlier backup remains available after a crash.
            if !self.isOpen || !self.restoreFailedTaskIfAvailable() { self.saveKeptDraft() }
            AtticSounds.play(.created)
            self.tasks.attachComposerFiles(submittedFiles, to: created.id) { [self] attached in
                recoveryOwner.endSaving(failedSubmission.id)
                if attached, !submittedFiles.isEmpty { retireFailedTask(failedSubmission.id) }
                else if !attached {
                    recoveryOwner.release(failedSubmission.id, by: self)
                    recoveryNotice("Task saved. Files kept for retry.")
                }
            }
            // A task "+" made while filtered stays in view (13 Nov), as
            // its first frame showed it.
            let destination: TasksTab = created.listedStatus == .backlog ? .backlog : .now
            self.tasks.keepInView(created.id, on: destination)
            self.tasks.unfoldAddedTask(created.id, on: destination)
            if openingPage {
                self.services.openTaskPage(created.id)
            } else if case let .tasks(tab) = submittedPage {
                if tab == .done || (tab == .backlog && status == .todo) {
                    self.services.toast(String(localized: "Added to Now"), self.undoCreation(in: submittedPage.history))
                } else {
                    self.tasks.addedRequest = TasksPageModel.ScrollRequest(id: created.id)
                }
            }
        })
        // From this point the card's words have moved to an asynchronous
        // save. Persist them before clearing the editor: quitting in that
        // interval must still leave a recoverable task.
        clearDraft()
        // The next task starts with the picked tags too (13 Nov).
        if !openingPage, case .tasks = page { tasks.startDraftFromFilter() }
        if openingPage { isOpen = false }
        else { fillCalendarDay(); focusRequest &+= 1 }
    }

    /// A draft kept aside while the other of Task and Note is being written
    /// (R-13). Task and Note share one draft (the add bar's), which is right
    /// until files are staged for a Task: the Task's title belongs with them.
    /// A Note made where it is not refused (`filesWaitForATask`) starts from
    /// its own draft, and the Task's waits here, files and all, until the card
    /// is on Task again.
    private struct AsideDraft {
        let owner: ComposerKind
        var text: TaskAddBarText
        var writing: String
        var pinned: Bool
        var history: TaskDraftHistory
        var caret: Int?
        var selection: NSRange?
        var seededTags: [String]?
        var dateAnchor: Date?
        var recoveringTaskID: UUID?
        var dateTimeZone: String? = nil
        var dateLocaleID: String? = nil
        var isEmpty: Bool { text == TaskAddBarText() && writing.isEmpty && !pinned }
    }
    private var asideDraft: AsideDraft?

    /// Once a Note can be submitted independently, the shared words belong
    /// with the staged Task files, even if a kind switch had already shown
    /// them on Note (where submission would have been refused).
    private func settleDraftOwner() {
        if let aside = asideDraft, kind == aside.owner {
            let current = draft(owner: aside.owner == .task ? .note : .task)
            restore(aside)
            let holdsFiles = current.owner == .task && tasks.composerFilesWait
            asideDraft = current.isEmpty && !holdsFiles ? nil : current
        } else if asideDraft == nil, kind == .note, tasks.composerFilesWait,
                  !page.kinds.contains(.task) || openedForQuickNote {
            asideDraft = draft(owner: .task)
            clearDraft()
        }
    }

    private func draft(owner: ComposerKind) -> AsideDraft {
        AsideDraft(owner: owner, text: tasks.addBar, writing: writing, pinned: pinned,
                   history: title.history, caret: title.caret, selection: title.selection, seededTags: title.seededTags ?? seededTags,
                   dateAnchor: title.dateAnchor, recoveringTaskID: recoveringFailedTaskID,
                   dateTimeZone: title.dateTimeZone, dateLocaleID: title.dateLocaleID)
    }

    private func restore(_ draft: AsideDraft) {
        if let selection = draft.selection ?? draft.caret.map({ NSRange(location: $0, length: 0) }) {
            editor.restoreSelection(selection, for: draft.text.text)
        }
        tasks.addBarState.clearDraft()
        tasks.addBar = draft.text
        title.history = draft.history
        title.caret = draft.caret
        title.selection = draft.selection
        writing = draft.writing
        pinned = draft.pinned
        seededTags = draft.seededTags
        title.seededTags = draft.seededTags
        title.dateAnchor = draft.dateAnchor
        title.dateTimeZone = draft.dateTimeZone
        title.dateLocaleID = draft.dateLocaleID
        recoveringFailedTaskID = draft.recoveringTaskID
    }

    /// ⇧⌘N asked for a note, not for the Task draft's files (see
    /// `filesWaitForATask`). Ends when the person picks a kind themselves.
    private var openedForQuickNote = false

    /// Files staged for a Task stay with the Task draft: a Note or Event made
    /// meanwhile is refused (with a toast) where the card can show them, which
    /// is any page that offers Task. Where it cannot (Notes), or for the quick
    /// note the person asked for, the note is made and the files stay staged,
    /// shown again on the Task card's chip and never attached to the note.
    private func filesWaitForATask() -> Bool {
        guard page.kinds.contains(.task), !openedForQuickNote, asideDraft?.owner != .task else { return false }
        return tasks.refuseNonTaskCreationWhileFilesWait()
    }

    /// Retire the Task identity and checkpoint the chosen kind in one write
    /// before its writer runs. A failed target save keeps that target draft;
    /// a failed checkpoint cannot create a Note/Event and leave a Task retry.
    private func prepareKindConversion() -> Bool {
        guard kind != .task, let id = recoveringFailedTaskID else {
            let ready = recoveryOwner.flush(services.drafts)
            if !ready { recoveryNotice() }
            return ready
        }
        do {
            let shown = try snapshot(text: tasks.addBar, writing: writing, owner: kind, pinned: pinned,
                seededTags: title.seededTags, anchor: title.dateAnchor, recoveryID: nil, files: [])
            let aside = try asideDraft.map { draft in
                try snapshot(text: draft.text, writing: draft.writing, owner: draft.owner, pinned: draft.pinned,
                    seededTags: draft.seededTags, anchor: draft.dateAnchor, recoveryID: draft.recoveringTaskID,
                    files: draft.owner == .task ? tasks.addBarState.files : [],
                    dateTimeZone: draft.dateTimeZone, dateLocaleID: draft.dateLocaleID)
            }
            let ready = recoveryOwner.retire([id], store: services.drafts,
                keepingPanel: services.drafts?.key ?? "composerKeptDraft", kept: .init(shown: shown, aside: aside))
            recoveringFailedTaskID = nil
            failedTaskContents[id] = nil
            recoveryOwner.release(id, by: self)
            if !ready { recoveryNotice() }
            return ready
        } catch { recoveryNotice("Couldn’t keep draft. Try again."); return false }
    }

    private func createImmediately(openingPage: Bool) -> Bool {
        guard isOpen, canCreate, kind != .event else { return false }
        if kind != .task, filesWaitForATask() || !prepareKindConversion() { return false }
        if kind == .task, !tasks.composerFilesReadyForSubmission() { return false }

        if kind == .task { return IdleLatencyTrace.span("task_add_submit") { createTask(openingPage: openingPage) } }
        return finishCreation(createNote(openingPage: openingPage), openingPage: openingPage)
    }

    /// Return or Create (P4): the card stays open, empty and ready for the
    /// next one, the keyboard still in its title. ⌘Return opens the new
    /// item's page, so the card folds.
    private func finishCreation(_ made: Bool, openingPage: Bool) -> Bool {
        failed = !made
        AtticSounds.play(made ? .created : .failed)
        guard made else { return false }
        if kind != .task { retireFailedTask(recoveringFailedTaskID) }
        clearDraft()
        if kind == .note, asideDraft == nil, tasks.composerFilesWait {
            // Files can finish arriving after an independent quick Note
            // opened. Its creation must leave an empty Task owner for them.
            asideDraft = AsideDraft(owner: .task, text: TaskAddBarText(), writing: "", pinned: false,
                history: TaskDraftHistory(), caret: nil, selection: nil, seededTags: nil,
                dateAnchor: nil, recoveringTaskID: nil)
        }
        // The next task starts with the picked tags too (13 Nov).
        if !openingPage, kind == .task, case .tasks = page { tasks.startDraftFromFilter() }
        if openingPage || kind != .task || !restoreFailedTaskIfAvailable() { saveKeptDraft() }
        if openingPage {
            isOpen = false
        } else {
            fillCalendarDay()
            focusRequest &+= 1
        }
        return true
    }

    private func createTask(openingPage: Bool) -> Bool {
        let failures = tasks.acknowledgementFailuresForComposer
        let before = tasks.acknowledgementRevision
        submitTaskAcknowledged(openingPage: openingPage)
        tasks.settlePendingCompletionAcknowledgements()
        return tasks.acknowledgementRevision != before && tasks.acknowledgementFailuresForComposer == failures
    }

    private func createEvent(openingPage: Bool, generation: Int) async -> EventSubmission {
        let input = tasks.addBar, inputWriting = writing, inputLength = eventLength
        let inputCalendar = calendarID
        if calendars.isEmpty { await loadCalendars() }
        guard generation == draftGeneration, tasks.addBar == input, writing == inputWriting,
              eventLength == inputLength else { return .notSubmitted }
        guard let writer = loadWriter(),
              let calendar = calendars.first(where: { $0.id == inputCalendar }) ?? calendars.first else { return .failed }
        guard calendarID == inputCalendar || calendarID == calendar.id else { return .notSubmitted }
        // As for a task: a day typed last replaces the picked one, even with
        // its word still at the caret; a lone time keeps the picked day.
        var finished = tasks.addBar
        let unchangedRecoveredDay = recoveringFailedEvent.map {
            $0.title == finished.text && $0.day == finished.picked.day
        } ?? false
        if !unchangedRecoveredDay && finished.typedReplacesPicks(parser: tasks.addBarParser, caret: nil) { tasks.addBar = finished }
        let values = values
        let clock = tasks.services.calendar()
        let day = values.day ?? tasks.addBarParser.today
        guard let draft = Self.eventDraft(title: values.title.isEmpty ? TaskDraftBuilder.collapsed(tasks.addBar.text) : values.title,
                                          day: day, time: values.time, length: eventLength,
                                          calendarID: calendar.id, calendar: clock, notes: writing) else { return .failed }
        let submitted = tasks.addBar
        let submittedWriting = writing, submittedCalendar = calendarID, submittedLength = eventLength
        let made = try? await writer.create(draft)
        let unchanged = generation == draftGeneration && tasks.addBar == submitted
            && writing == submittedWriting && calendarID == submittedCalendar && eventLength == submittedLength
        guard let made else { return .failed }
        guard unchanged else { return .saved(current: false) }
        calendarID = calendar.id
        if openingPage { services.openEvent(made) }
        return .saved(current: true)
    }

    /// A timed event lasts `length` minutes; one with no time is all day
    /// (end exclusive, the next local midnight).
    nonisolated static func eventDraft(title: String, day: DueDay, time: Int?, length: Int,
                                       calendarID: String, calendar: Calendar, notes: String = "") -> CalendarEventDraft? {
        let calendar = DueDay.storageCalendar(matching: calendar)
        let zone = calendar.timeZone.identifier
        // The writing line becomes the event's notes; an empty line writes none.
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = trimmed.isEmpty ? nil : trimmed
        var components = DateComponents(year: day.year, month: day.month, day: day.day)
        if let time {
            components.hour = time / 60
            components.minute = time % 60
            guard let start = calendar.date(from: components) else { return nil }
            return CalendarEventDraft(title: title, start: start, length: TimeInterval(length * 60),
                                      calendarID: calendarID, timeZoneID: zone, notes: notes)
        }
        guard let start = calendar.date(from: components),
              let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return CalendarEventDraft(title: title, start: start, end: end, isAllDay: true, calendarID: calendarID,
                                  timeZoneID: zone, notes: notes)
    }

    private func createNote(openingPage: Bool) -> Bool {
        let values = values
        let title = values.title.isEmpty ? TaskDraftBuilder.collapsed(tasks.addBar.text) : values.title
        guard let id = tasks.library.createNote(title: title, body: writing, tags: values.tags,
                                                pinned: pinned, in: page.history) else { return false }
        if openingPage { services.openNote(id) } else { services.toast(String(localized: "Added to Notes"), undoCreation()) }
        return true
    }

    /// The draft is used up: title, picks, writing and pin. The event's
    /// length and calendar stay as the person last chose them.
    func clearDraft() {
        title.clearDraft()
        writing = ""
        pinned = false
        recoveringFailedEvent = nil
        recoveringFailedTaskID = nil
    }

    // MARK: Calendars

    private func loadWriter() -> CalendarEventWriter? {
        if let writer { return writer }
        writer = try? services.makeWriter?()
        return writer
    }

    private func requestCalendars() {
        Task { [weak self] in await self?.loadCalendars() }
    }

    func loadCalendars() async {
        guard let writer = loadWriter() else { return }
        let load: Task<[CalendarWriteCalendar], Never>
        if let calendarLoad { load = calendarLoad }
        else {
            calendarLoadGeneration += 1
            load = Task { (try? await writer.writableCalendars()) ?? [] }
            calendarLoad = load
        }
        let generation = calendarLoadGeneration
        let list = await load.value
        guard !Task.isCancelled, generation == calendarLoadGeneration else { return }
        calendarLoad = nil
        if list != calendars { calendars = list }
        if let calendarID, list.contains(where: { $0.id == calendarID }) { return }
        calendarID = list.first?.id
    }

    // MARK: Undo

    /// ⌘Z past the title's own typing: the page's history.
    /// ⌘Return on an event: Calendar.app at it, through the card's writer.
    func openInCalendar(_ event: CalendarOwnedEvent) async {
        try? await loadWriter()?.openInCalendar(event.occurrenceID)
    }

    /// The Undo a creation's toast offers: the history the creation went
    /// into, fixed now (the card may be on another page by the click).
    private func undoCreation(in submittedHistory: UndoHistoryID? = nil) -> @MainActor () -> CommandOutcome {
        let library = tasks.library
        let history = submittedHistory ?? page.history
        let step = library.undo.undoStepID(in: history)
        return {
            guard let step, library.undo.undoStepID(in: history) == step else { return .applied }
            return library.undo(in: history)
        }
    }

    func undoPage() {
        let history = page.history, library = tasks.library
        if history == .calendar { Task { await library.replay(in: history, redo: false) } }
        else { _ = library.undo(in: history) }
    }
    func redoPage() {
        let history = page.history, library = tasks.library
        if history == .calendar { Task { await library.replay(in: history, redo: true) } }
        else { _ = library.redo(in: history) }
    }
}
