import AppKit
import Foundation
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

    let defaults: UserDefaults
    var key = "composerKeptDraft"

    func load() -> Draft? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Draft.self, from: data)
    }

    func save(_ draft: Draft?) {
        guard let draft, !(draft.title.isEmpty && draft.writing.isEmpty) else {
            if defaults.object(forKey: key) != nil { defaults.removeObject(forKey: key) }
            return
        }
        guard load() != draft, let data = try? JSONEncoder().encode(draft) else { return }
        defaults.set(data, forKey: key)
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

    static let lengths = [30, 60, 90, 120]

    init(tasks: TasksPageModel, services: ComposerServices = ComposerServices()) {
        self.tasks = tasks
        self.services = services
        failedEventDrafts = services.drafts?.loadFailedEvents() ?? []
        restoreKeptDraft()
    }

    // MARK: The kept draft (A2)

    /// A draft saved before a quit comes back into an empty card.
    private func restoreKeptDraft() {
        guard let saved = services.drafts?.load(), tasks.addBar.text.isEmpty, writing.isEmpty else { return }
        tasks.addBar = TaskAddBarText(text: saved.title)
        writing = saved.writing
        if let kind = ComposerKind(rawValue: saved.kind) { self.kind = kind }
    }

    /// Saves what the card holds now (or forgets it once used up). Called
    /// when the card closes, after a creation and as the app quits.
    func saveKeptDraft() {
        guard let drafts = services.drafts else { return }
        drafts.save(hasDraft ? ComposerDraftStore.Draft(title: tasks.addBar.text, writing: writing, kind: kind.rawValue) : nil)
    }

    var title: TasksAddBarState { tasks.addBarState }
    var kinds: [ComposerKind] { page.kinds }

    var hasDraft: Bool {
        !TaskDraftBuilder.collapsed(tasks.addBar.text).isEmpty
            || !writing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canCreate: Bool { !isCreating && !TaskDraftBuilder.collapsed(tasks.addBar.text).isEmpty }

    // MARK: Opening and closing

    /// An empty draft starts with `tags` (a filtered page's picked tags),
    /// so what is made there stays in view.
    func startTags(_ tags: [String]) {
        guard !tags.isEmpty, tasks.addBar == TaskAddBarText(), writing.isEmpty else { return }
        tasks.addBar.picked.tags = tags
    }

    /// "+" opens on the page's own kind unless a note draft was kept; ⇧⌘N
    /// asks for Note. A kept event draft is a task outside Calendar.
    func open(on page: ComposerPage, as requested: ComposerKind? = nil) {
        draftGeneration += 1
        let keptNote = kind == .note && hasDraft
        self.page = page
        if let requested, page.kinds.contains(requested) || requested == .note {
            kind = requested
        } else if !keptNote {
            kind = page.ownKind
        }
        if !page.kinds.contains(kind) { kind = kind == .event ? .task : page.ownKind }
        if !page.kinds.contains(kind) { kind = .note }
        if kind != .event { recoveringFailedEvent = nil }
        let recovered = restoreFailedEventIfAvailable()
        fillCalendarDay()
        if kind == .event { requestCalendars() }
        failed = kind == .event && (recovered
            || failedEventDrafts.contains(where: { $0.title == tasks.addBar.text && $0.writing == writing }))
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
        draftGeneration += 1
        if newKind != .event { recoveringFailedEvent = nil }
        let recovered = restoreFailedEventIfAvailable()
        fillCalendarDay()
        if newKind == .event { requestCalendars() }
        failed = newKind == .event && (recovered
            || failedEventDrafts.contains(where: { $0.title == tasks.addBar.text && $0.writing == writing }))
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
        guard isOpen, canCreate else { return }
        var finished = tasks.addBar
        finished.typedReplacesPicks(parser: tasks.parser, caret: nil)
        let day = finished.parts(parser: tasks.parser).dueDay
        // In Progress while Now shows only that (13 Nov), so the task
        // doesn't vanish as you make it.
        let status: TaskStatus = page == .tasks(.backlog) && day == nil ? .backlog
            : page.tasksTab.map(tasks.newOpenStatus(from:)) ?? .todo
        guard let draft = finished.draft(parser: tasks.parser, status: status) else { return }
        let submittedWriting = writing, submittedPage = page
        // A file dropped into the next draft while the first saves belongs
        // to the next draft, even if the first save finishes afterwards.
        let submittedFiles = tasks.takeComposerFiles()
        isCreating = true
        tasks.createAcknowledged(draft, save: { [library = tasks.library] id in
            library.createTask(draft, writing: submittedWriting, in: submittedPage.history, id: id)
        }, settled: { [weak self] created in
            guard let self else { return }
            self.isCreating = false
            guard let created else {
                self.failed = true
                AtticSounds.play(.failed)
                self.tasks.restoreComposerFiles(submittedFiles)
                // Another submission can have its own text already. Never
                // overwrite it with a failed older draft.
                if self.tasks.addBar.text.isEmpty && self.writing.isEmpty {
                    self.tasks.addBar = finished
                    self.writing = submittedWriting
                }
                self.isOpen = true
                self.focusRequest &+= 1
                self.saveKeptDraft()
                return
            }
            self.failed = false
            // Only retire a kept draft after the task's family write commits.
            // Until then an earlier backup remains available after a crash.
            self.saveKeptDraft()
            AtticSounds.play(.created)
            self.tasks.attachComposerFiles(submittedFiles, to: created.id)
            // A task "+" made while filtered stays in view (13 Nov), as
            // its first frame showed it.
            if let tab = submittedPage.tasksTab { self.tasks.keepInView(created.id, on: tab) }
            if openingPage {
                self.services.openTaskPage(created.id)
            } else if case let .tasks(tab) = submittedPage {
                if tab == .done || (tab == .backlog && status == .todo) {
                    self.services.toast(String(localized: "Added to Now"), self.undoCreation())
                } else {
                    self.tasks.addedRequest = TasksPageModel.ScrollRequest(id: created.id)
                }
            }
        })
        clearDraft()
        // The next task starts with the picked tags too (13 Nov).
        if case .tasks = page { tasks.startDraftFromFilter() }
        if openingPage { isOpen = false }
        else { focusRequest &+= 1 }
    }

    private func createImmediately(openingPage: Bool) -> Bool {
        guard isOpen, canCreate, kind != .event else { return false }
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
        if kind == .task, case .tasks = page { tasks.startDraftFromFilter() }
        saveKeptDraft()
        if openingPage {
            isOpen = false
        } else {
            focusRequest &+= 1
        }
        return true
    }

    private func createTask(openingPage: Bool) -> Bool {
        var finished = tasks.addBar
        finished.typedReplacesPicks(parser: tasks.parser, caret: nil)
        tasks.addBar = finished
        let day = finished.parts(parser: tasks.parser).dueDay
        // Later makes an undated put-off task; Done (and a dated task from
        // Later) creates in Now.
        // In Progress while Now shows only that (13 Nov), so the task
        // doesn't vanish as you make it.
        let status: TaskStatus = page == .tasks(.backlog) && day == nil ? .backlog
            : page.tasksTab.map(tasks.newOpenStatus(from:)) ?? .todo
        guard let draft = finished.draft(parser: tasks.parser, status: status),
              let task = tasks.library.createTask(draft, writing: writing, in: page.history) else { return false }
        tasks.attachComposerFiles(to: task.id)
        if let tab = page.tasksTab { tasks.keepInView(task.id, on: tab) }
        if openingPage {
            services.openTaskPage(task.id)
        } else if case let .tasks(tab) = page {
            if tab == .done || (tab == .backlog && status == .todo) {
                services.toast(String(localized: "Added to Now"), undoCreation())
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
    private func undoCreation() -> @MainActor () -> CommandOutcome {
        let library = tasks.library
        let history = page.history
        return { library.undo(in: history) }
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
