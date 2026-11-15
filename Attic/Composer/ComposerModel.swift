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
}

/// A draft kept with Escape or a click outside, saved so it comes back
/// after the app quits and relaunches (UX audit A2). Only the words are
/// kept: the title's text, the writing and the kind it was typed as.
struct ComposerDraftStore {
    struct Draft: Codable, Equatable {
        var title: String
        var writing: String
        var kind: String
        var recoveringTaskID: UUID? = nil
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
            var result = TaskAddBarText(text: title)
            result.picked.day = pickedDay
            result.picked.priority = pickedPriority
            result.picked.tags = pickedTags
            return result
        }
    }

    let defaults: UserDefaults
    var key = "composerKeptDraft"
    /// Production supplies a sidecar next to its local store. Tests must
    /// explicitly supply a temporary URL; nil retains the legacy test seam.
    var taskRecoveryURL: URL? = nil
    var persistTaskRecovery: (Data, URL) throws -> Void = ComposerDraftStore.writeTaskRecovery

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
    }

    private func loadLegacyKeptDrafts() -> KeptDrafts? {
        guard let data = defaults.data(forKey: key) else { return nil }
        if let kept = try? JSONDecoder().decode(KeptDrafts.self, from: data) { return kept }
        // The former single-entry format remains readable without changing
        // its words or kind. The next save writes the owned format.
        return (try? JSONDecoder().decode(Draft.self, from: data)).map { KeptDrafts(shown: $0) }
    }

    func loadKeptDrafts() -> KeptDrafts? {
        guard let recovery = try? readRecovery() else { return nil }
        guard let shown = recovery.draft else {
            return recovery.aside.map { KeptDrafts(shown: $0) }
        }
        return KeptDrafts(shown: shown, aside: recovery.aside)
    }

    @discardableResult
    func saveKeptDrafts(_ kept: KeptDrafts) -> Bool {
        if taskRecoveryURL != nil {
            do {
                var recovery = try readRecovery()
                recovery.draft = kept.shown
                recovery.aside = kept.aside
                try persistRecovery(recovery)
                return true
            } catch { return false }
        }
        guard !kept.shown.title.isEmpty || !kept.shown.writing.isEmpty || kept.aside != nil else {
            defaults.removeObject(forKey: key)
            return true
        }
        guard let data = try? JSONEncoder().encode(kept) else { return false }
        defaults.set(data, forKey: key)
        return true
    }

    private func loadLegacyDraft() -> Draft? { loadLegacyKeptDrafts()?.shown }

    func load() -> Draft? {
        if let taskRecoveryURL, FileManager.default.fileExists(atPath: taskRecoveryURL.path) {
            return (try? readRecovery())?.draft
        }
        return loadKeptDrafts().map { $0.shown.title.isEmpty && $0.shown.writing.isEmpty ? ($0.aside ?? $0.shown) : $0.shown }
    }

    @discardableResult
    func save(_ input: Draft?) -> Bool {
        let draft = input.flatMap { $0.title.isEmpty && $0.writing.isEmpty ? nil : $0 }
        if taskRecoveryURL != nil {
            do {
                var recovery = try readRecovery()
                recovery.draft = draft
                recovery.aside = nil
                try persistRecovery(recovery)
                return true
            } catch { return false }
        }
        guard let draft else {
            if defaults.object(forKey: key) != nil { defaults.removeObject(forKey: key) }
            return true
        }
        guard loadLegacyDraft() != draft else { return true }
        guard let data = try? JSONEncoder().encode(draft) else { return false }
        defaults.set(data, forKey: key)
        return true
    }

    func loadFailedEvents() -> [FailedEvent] {
        guard let data = defaults.data(forKey: key + ".failedEvents") else { return [] }
        return (try? JSONDecoder().decode([FailedEvent].self, from: data)) ?? []
    }

    func saveFailedEvents(_ events: [FailedEvent]) {
        let storageKey = key + ".failedEvents"
        guard !events.isEmpty else { defaults.removeObject(forKey: storageKey); return }
        guard let data = try? JSONEncoder().encode(events) else { return }
        defaults.set(data, forKey: storageKey)
    }

    func loadFailedTasks() -> [FailedTask] {
        (try? readFailedTasks()) ?? []
    }

    func readFailedTasks() throws -> [FailedTask] { try readRecovery().tasks }

    private func readRecovery() throws -> TaskRecovery {
        if let taskRecoveryURL, FileManager.default.fileExists(atPath: taskRecoveryURL.path) {
            let bytes = try Data(contentsOf: taskRecoveryURL)
            if let recovery = try? JSONDecoder().decode(TaskRecovery.self, from: bytes) { return recovery }
            // Adopt the earlier pending-only JSON without a SwiftData migration.
            return TaskRecovery(tasks: try JSONDecoder().decode([FailedTask].self, from: bytes), draft: loadLegacyDraft(), aside: loadLegacyKeptDrafts()?.aside)
        }
        let tasks = try defaults.data(forKey: key + ".failedTasks").map {
            try JSONDecoder().decode([FailedTask].self, from: $0)
        } ?? []
        return TaskRecovery(tasks: tasks, draft: loadLegacyDraft(), aside: loadLegacyKeptDrafts()?.aside)
    }

    private func persistRecovery(_ recovery: TaskRecovery) throws {
        guard let taskRecoveryURL else { return }
        let previous = try readRecovery() // unreadable ownership is never overwritten
        if previous != recovery || !FileManager.default.fileExists(atPath: taskRecoveryURL.path) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            try persistTaskRecovery(try encoder.encode(recovery), taskRecoveryURL)
        }
        // The durable document now supersedes both legacy defaults keys.
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: key + ".failedTasks")
    }

    @discardableResult
    func saveFailedTasks(_ tasks: [FailedTask], consumingKeptDraft: Bool = false) -> Bool {
        if taskRecoveryURL != nil {
            do {
                var recovery = try readRecovery()
                recovery.tasks = tasks
                if consumingKeptDraft { recovery.draft = nil }
                try persistRecovery(recovery)
                return true
            } catch { return false }
        }
        let storageKey = key + ".failedTasks"
        guard let data = try? JSONEncoder().encode(tasks) else { return false }
        if tasks.isEmpty { defaults.removeObject(forKey: storageKey) }
        else { defaults.set(data, forKey: storageKey) }
        if consumingKeptDraft { save(nil) }
        return true
    }

}

/// The "+" card's state. It lives as long as the panel, so a draft dismissed
/// with Escape or a click outside is there again on the next "+", on any page.
/// The title is the add bar's draft (`TasksPageModel.addBarState`): its
/// shorthand, picks, suggestions and typing Undo carry over unchanged.
@MainActor
final class ComposerModel: ObservableObject {
    let tasks: TasksPageModel
    var services: ComposerServices

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
    private var failedTaskDrafts: [ComposerDraftStore.FailedTask] = []
    private var failedTaskContents: [UUID: (title: TaskAddBarText, files: [TasksComposerFiles])] = [:]
    private var recoveringFailedTaskID: UUID?
    private var taskRecoveryReadable = true


    static let lengths = [30, 60, 90, 120]

    init(tasks: TasksPageModel, services: ComposerServices = ComposerServices()) {
        self.tasks = tasks
        self.services = services
        failedEventDrafts = services.drafts?.loadFailedEvents() ?? []
        do { failedTaskDrafts = try services.drafts?.readFailedTasks() ?? [] }
        catch { taskRecoveryReadable = false }
        // The process may have stopped after the physical save but before
        // dismissing the pending recovery record. A UUID already in the
        // store is proof that submission succeeded; never submit it twice.
        let keptRecoveryID = services.drafts?.load()?.recoveringTaskID
        if !failedTaskDrafts.isEmpty || keptRecoveryID != nil {
            do {
                let ids = failedTaskDrafts.map(\.id) + [keptRecoveryID].compactMap { $0 }
                let persisted = try ModelContext(tasks.store.container).fetch(FetchDescriptor<TaskItem>(
                    predicate: #Predicate { ids.contains($0.id) }))
                let committed = Set(persisted.map(\.id)) // includes tombstones and every replica
                if let kept = services.drafts?.load(), let id = kept.recoveringTaskID, committed.contains(id) {
                    services.drafts?.save(nil)
                }
                failedTaskDrafts.removeAll { committed.contains($0.id) }
                if !committed.isEmpty { services.drafts?.saveFailedTasks(failedTaskDrafts) }
            } catch { taskRecoveryReadable = false }
        }
        restoreKeptDraft()
        _ = restoreFailedTaskIfAvailable(restoringKeptDraft: true)
    }

    // MARK: The kept draft (A2)

    /// A draft saved before a quit comes back into an empty card.
    private func restoreKeptDraft() {
        guard let kept = services.drafts?.loadKeptDrafts(), tasks.addBar.text.isEmpty, writing.isEmpty else { return }
        let saved = kept.shown
        tasks.addBar = TaskAddBarText(text: saved.title)
        writing = saved.writing
        if let kind = ComposerKind(rawValue: saved.kind) { self.kind = kind }
        if let aside = kept.aside, let owner = ComposerKind(rawValue: aside.kind) {
            asideDraft = AsideDraft(owner: owner, text: TaskAddBarText(text: aside.title), writing: aside.writing,
                pinned: false, history: TaskDraftHistory(), caret: nil, selection: nil, seededTags: nil)
        }
    }

    @discardableResult
    private func rememberFailedTask(_ draft: ComposerDraftStore.FailedTask,
                                    title: TaskAddBarText, files: [TasksComposerFiles], consumingKeptDraft: Bool = false) -> Bool {
        var pending = failedTaskDrafts
        if let index = pending.firstIndex(where: { $0.id == draft.id }) {
            pending[index] = draft
        } else {
            pending.append(draft)
        }
        let preserved = services.drafts?.saveFailedTasks(pending, consumingKeptDraft: consumingKeptDraft) != false
        failedTaskDrafts = pending
        // A write can report failure after replacement. Keep its logical ID,
        // while the editor still owns files that have not been submitted.
        failedTaskContents[draft.id] = (title, consumingKeptDraft && !preserved ? [] : files)
        return preserved
    }

    private func retireFailedTask(_ id: UUID?) {
        guard let id else { return }
        failedTaskDrafts.removeAll { $0.id == id }
        failedTaskContents[id] = nil
        services.drafts?.saveFailedTasks(failedTaskDrafts)
    }

    /// A failed task waits behind a newer draft. Once that draft is used,
    /// restore the oldest failed task with its own staged files. Its text,
    /// picks and original page also survive a panel-model relaunch.
    @discardableResult
    private func restoreFailedTaskIfAvailable(restoringKeptDraft: Bool = false) -> Bool {
        guard kind == .task, !isCreating, tasks.addBarState.stagingFiles == 0 else { return false }
        let preferredID = recoveringFailedTaskID ?? (restoringKeptDraft ? services.drafts?.load()?.recoveringTaskID : nil)
        guard let saved = preferredID.flatMap({ id in failedTaskDrafts.first { $0.id == id } })
                ?? failedTaskDrafts.first else { return false }
        let alreadyRecovering = recoveringFailedTaskID == saved.id
        // Identical words can belong to a genuinely newer draft with other
        // picks or files. Only the kept card's submission identity proves
        // that an occupied editor belongs to this recovery record.
        let keptRecovery = restoringKeptDraft && services.drafts?.load()?.recoveringTaskID == saved.id
        guard !hasDraft || alreadyRecovering || keptRecovery,
              tasks.addBarState.files.isEmpty || alreadyRecovering else { return false }
        if !alreadyRecovering {
            let keptTitle = tasks.addBar.text
            tasks.addBar = failedTaskContents[saved.id]?.title ?? saved.addBar
            if keptRecovery { tasks.addBar.text = keptTitle }
            else { writing = saved.writing }
            if let contents = failedTaskContents[saved.id] {
                tasks.restoreComposerFiles(contents.files)
                // Ownership moves to the editor. Keeping a second copy here
                // could later advertise files the user removed from the card.
                failedTaskContents[saved.id] = (contents.title, [])
            }
        }
        recoveringFailedTaskID = saved.id
        failed = true
        saveKeptDraft()
        return true
    }

    /// Saves what the card holds now (or forgets it once used up). Called
    /// when the card closes, after a creation and as the app quits.
    func saveKeptDraft() {
        guard let drafts = services.drafts else { return }
        drafts.saveKeptDrafts(ComposerDraftStore.KeptDrafts(
            shown: .init(title: tasks.addBar.text, writing: writing, kind: kind.rawValue, recoveringTaskID: recoveringFailedTaskID),
            aside: asideDraft.map { .init(title: $0.text.text, writing: $0.writing, kind: $0.owner.rawValue) }))

    }

    var title: TasksAddBarState { tasks.addBarState }
    var kinds: [ComposerKind] { page.kinds }

    var hasDraft: Bool {
        !TaskDraftBuilder.collapsed(tasks.addBar.text).isEmpty
            || !writing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        if !hasDraft {
            if tasks.addBar.picked.tags == title.seededTags { tasks.addBar.picked.tags = [] }
            title.seededTags = nil
        }
        restoreFocus()
        saveKeptDraft()
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
              tasks.addBar.parts(parser: tasks.parser).dueDay == nil else { return }
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
        tasks.addBar.activeTokens(parser: tasks.parser).filter { reads($0.value) }
    }

    /// The tinted pieces of the title line.
    var chips: [AtticTokenChip] {
        let text = tasks.addBar
        let ranges = tokens.map { $0.utf16Range(in: text.text) }
        return text.tokenChips(parser: tasks.parser, caret: title.caret).filter { ranges.contains($0.range) }
    }

    /// A suggestion this kind can use: tags for a task or note, days for a
    /// task or event.
    func suggestion(focused: Bool) -> TaskAddBarText.Suggestion? {
        guard focused, let suggestion = tasks.addBar.suggestion(parser: tasks.parser, caret: title.caret, tags: tasks.cachedTags),
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
            let parts = text.parts(parser: tasks.parser)
            return Values(title: parts.title, day: parts.dueDay, time: parts.dueTimeMinutes,
                          priority: parts.priority, tags: parts.tags)
        case .event:
            let parts = text.parts(parser: tasks.parser)
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
        guard !filesWaitForATask() else { return false }
        isCreating = true
        defer { isCreating = false }
        let generation = draftGeneration
        // Resolve a typed date against a picked date exactly as createEvent
        // does. Persisting the earlier pick would retry on the wrong day.
        var normalized = tasks.addBar
        normalized.typedReplacesPicks(parser: tasks.parser, caret: nil)
        let submitted = ComposerDraftStore.FailedEvent(title: tasks.addBar.text, writing: writing,
            day: normalized.parts(parser: tasks.parser).dueDay, length: eventLength, calendarID: calendarID)
        switch await createEvent(openingPage: openingPage, generation: generation) {
        case .notSubmitted:
            return false
        case .failed:
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
            let recovered = recoveringFailedEvent
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
        guard taskRecoveryReadable else { failed = true; AtticSounds.play(.failed); return }

        var finished = tasks.addBar
        finished.typedReplacesPicks(parser: tasks.parser, caret: nil)
        let day = finished.parts(parser: tasks.parser).dueDay
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
        guard let draft = finished.draft(parser: tasks.parser, status: status) else { return }
        let submittedWriting = writing
        let failedSubmission = ComposerDraftStore.FailedTask(id: recovering?.id ?? UUID(),
            title: finished, writing: submittedWriting, status: status, page: submittedPage)
        // A failed recovery write leaves the editor and its files untouched;
        // no optimistic row or asynchronous store command has been issued.
        guard rememberFailedTask(failedSubmission, title: finished, files: tasks.addBarState.files, consumingKeptDraft: true) else {
            recoveringFailedTaskID = failedSubmission.id
            failed = true
            AtticSounds.play(.failed)
            return
        }
        // A file dropped into the next draft while the first saves belongs
        // to the next draft, even if the first save finishes afterwards.
        let submittedFiles = tasks.takeComposerFiles()
        isCreating = true
        tasks.createAcknowledged(draft, id: failedSubmission.id, save: { [library = tasks.library] id in
            library.createTask(draft, writing: submittedWriting, in: submittedPage.history, id: id)
        }, settled: { [weak self] created in
            guard let self else { return }
            self.isCreating = false
            guard let created else {
                self.failed = true
                AtticSounds.play(.failed)
                self.rememberFailedTask(failedSubmission, title: finished, files: submittedFiles)
                // Recover as soon as there is no newer draft to displace.
                // Its files must travel with its own words, never with the
                // next task's attachment strip.
                let recovered = self.restoreFailedTaskIfAvailable()
                if !recovered { self.saveKeptDraft() }
                self.isOpen = true
                if recovered { self.focusRequest &+= 1 }
                return
            }
            self.failed = false
            self.retireFailedTask(failedSubmission.id)
            // Only retire a kept draft after the task's family write commits.
            // Until then an earlier backup remains available after a crash.
            if !self.isOpen || !self.restoreFailedTaskIfAvailable() { self.saveKeptDraft() }
            AtticSounds.play(.created)
            self.tasks.attachComposerFiles(submittedFiles, to: created.id)
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
                   history: title.history, caret: title.caret, selection: title.selection, seededTags: seededTags)
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
        guard page.kinds.contains(.task), !openedForQuickNote else { return false }
        return tasks.refuseNonTaskCreationWhileFilesWait()
    }

    private func createImmediately(openingPage: Bool) -> Bool {
        guard isOpen, canCreate, kind != .event else { return false }
        if kind != .task, filesWaitForATask() { return false }
        if kind == .task, !tasks.composerFilesReadyForSubmission() { return false }

        let made = kind == .task
            ? IdleLatencyTrace.span("task_add_submit") { createTask(openingPage: openingPage) }
            : createNote(openingPage: openingPage)
        return finishCreation(made, openingPage: openingPage)
    }

    /// Return or Create (P4): the card stays open, empty and ready for the
    /// next one, the keyboard still in its title. ⌘Return opens the new
    /// item's page, so the card folds.
    private func finishCreation(_ made: Bool, openingPage: Bool) -> Bool {
        failed = !made
        AtticSounds.play(made ? .created : .failed)
        guard made else { return false }
        clearDraft()
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
        guard tasks.composerFilesReadyForSubmission() else { return false }
        guard taskRecoveryReadable else { return false }

        var finished = tasks.addBar
        finished.typedReplacesPicks(parser: tasks.parser, caret: nil)
        tasks.addBar = finished
        let day = finished.parts(parser: tasks.parser).dueDay
        let recovering = recoveringFailedTaskID.flatMap { id in failedTaskDrafts.first { $0.id == id } }
        let submittedPage = recovering?.page ?? page
        // Later makes an undated put-off task; Done (and a dated task from
        // Later) creates in Now.
        // In Progress while Now shows only that (13 Nov), so the task
        // doesn't vanish as you make it.
        let status: TaskStatus
        if let recovering {
            status = submittedPage == .tasks(.backlog)
                ? (day == nil ? .backlog : .todo) : recovering.status
        } else {
            status = submittedPage == .tasks(.backlog) && day == nil ? .backlog
                : submittedPage.tasksTab.map(tasks.newOpenStatus(from:)) ?? .todo
        }
        guard let draft = finished.draft(parser: tasks.parser, status: status),
              let task = tasks.library.createTask(draft, writing: writing, in: submittedPage.history, id: recovering?.id) else { return false }
        retireFailedTask(recovering?.id)
        tasks.attachComposerFiles(to: task.id)
        let destination: TasksTab = task.listedStatus == .backlog ? .backlog : .now
        tasks.keepInView(task.id, on: destination)
        tasks.unfoldAddedTask(task.id, on: destination)

        if openingPage {
            services.openTaskPage(task.id)
        } else if case let .tasks(tab) = submittedPage {
            if tab == .done || (tab == .backlog && status == .todo) {
                services.toast(String(localized: "Added to Now"), undoCreation(in: submittedPage.history))
            } else {
                tasks.addedRequest = TasksPageModel.ScrollRequest(id: task.id)
            }
        }
        return true
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
        if !unchangedRecoveredDay && finished.typedReplacesPicks(parser: tasks.parser, caret: nil) { tasks.addBar = finished }
        let values = values
        let clock = tasks.services.calendar()
        let day = values.day ?? tasks.parser.today
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
